@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreImage
import RecorderCore

private typealias ScreenPreviewProvider = (
    ScreenCaptureTarget,
    Bool
) async throws -> CGImage

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedSection: AppSection = .record
    @Published var configuration: RecordingConfiguration {
        didSet {
            persistSettings()
            refreshEncoderPreflight()
        }
    }
    @Published private(set) var snapshot = RecordingSnapshot.idle
    @Published private(set) var cameras = [CaptureDeviceDescriptor]()
    @Published private(set) var microphones = [CaptureDeviceDescriptor]()
    @Published private(set) var folderURL: URL?
    @Published private(set) var recordings = [RecordingArtifact]()
    @Published var selectedRecording: RecordingArtifact?
    @Published private(set) var screenPreview: NSImage?
    @Published private(set) var screenPreviewMessage: String?
    @Published private(set) var permissions = [PermissionKind: PermissionStatus]()
    @Published var errorMessage: String?
    @Published var noticeMessage: String?
    @Published var invalidRecoveryFiles = [URL]()
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var highQualityIssue: String?
    @Published private(set) var microphoneLevel = 0.0
    @Published private(set) var systemAudioLevel = 0.0
    @Published private(set) var recordingCameraPreview: NSImage?
    @Published private(set) var isRecordingCameraPreviewVisible = true
    @Published private(set) var isChangingCombinedCamera = false
    @Published private(set) var isChoosingScreen = false

    let cameraPreview = CameraPreviewController()
    private let microphoneMeter = MicrophoneMeterController()
    private let systemAudioMeter = SystemAudioMeterController()
    private let picker = ScreenContentPicker()
    private let regionSelector = RegionSelectionController()
    private let folderStore = RecordingFolderStore()
    private let library: any RecordingLibrary = LocalRecordingLibrary()
    private let recovery = InterruptedRecordingRecovery()
    private let screenPreviewProvider: ScreenPreviewProvider
    private var folderAccess: ScopedFolderAccess?
    private(set) var screenTarget: ScreenCaptureTarget?
    private var previewTask: Task<Void, Never>?
    private var screenPreviewGeneration = UUID()
    private var timerTask: Task<Void, Never>?
    private var recordTask: Task<Void, Never>?
    private var deviceObservers = [NSObjectProtocol]()
    private var workspaceObservers = [NSObjectProtocol]()
    private let controllerWindow = RecordingControllerWindowManager()
    private let recordingPreviewContext = CIContext(
        options: [.cacheIntermediates: false]
    )
    private var hasBootstrapped = false

    private var isUITesting: Bool {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing-ready")
            || arguments.contains("--ui-testing-unready")
            || arguments.contains("--ui-testing-recording-controller")
            || arguments.contains(
                "--ui-testing-combined-recording-controller"
            )
            || arguments.contains("--ui-testing-selecting")
            || arguments.contains("--ui-testing-window-content")
#else
        return false
#endif
    }

    private lazy var engine = RecordingEngine(
        factory: LiveRecordingPipelineFactory(),
        updateHandler: { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.apply(snapshot)
            }
        },
        previewHandler: { [weak self] frame in
            await self?.applyRecordingPreview(frame)
        }
    )

    init() {
        screenPreviewProvider = Self.makeScreenPreviewProvider()
        configuration = Self.loadSettings()
        for kind in PermissionKind.allCases {
            permissions[kind] = PermissionService.status(for: kind)
        }
    }

    deinit {
        previewTask?.cancel()
        timerTask?.cancel()
        recordTask?.cancel()
        for observer in deviceObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    var canRecord: Bool {
        guard folderURL != nil,
              configuration.validationIssues(
                hasResolvedScreenTarget: screenTarget != nil
              ).isEmpty else {
            return false
        }
        if configuration.mode.needsScreen, permissions[.screen] != .authorized {
            return false
        }
        if configuration.mode.needsCamera, permissions[.camera] != .authorized {
            return false
        }
        if configuration.capturesMicrophone, permissions[.microphone] != .authorized {
            return false
        }
        if configuration.quality == .high, highQualityIssue != nil {
            return false
        }
        return [.idle, .completed, .failed].contains(snapshot.phase)
    }

    var hasSelectedWindow: Bool {
        screenTarget != nil
            && configuration.screenSelection?.kind == .window
    }

    var recordsWindowContentOnly: Bool {
        hasSelectedWindow && configuration.windowContentCrop != nil
    }

    var windowControlsHeightPoints: Double {
        configuration.windowContentCrop?.topInsetPoints
            ?? WindowContentCrop.defaultTopInsetPoints
    }

    var maximumWindowControlsHeightPoints: Double {
        let height = screenTarget?.capturePointSize.height ?? 360
        return Double(max(41, min(300, height - 80)))
    }

    var elapsedText: String {
        let hours = elapsedSeconds / 3_600
        let minutes = (elapsedSeconds % 3_600) / 60
        let seconds = elapsedSeconds % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    var needsTerminationDelay: Bool {
        [.countingDown, .recording, .paused, .finalizing].contains(snapshot.phase)
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
#if DEBUG
        if await bootstrapForUITestingIfNeeded() {
            return
        }
#endif
        refreshDevices()
        refreshPermissions()
        do {
            folderAccess = try folderStore.resolve()
            folderURL = folderAccess?.url
        } catch {
            errorMessage = "The saved recording folder could not be opened. Choose it again."
        }
        if configuration.cameraDeviceID == nil {
            configuration.cameraDeviceID = cameras.first?.id
        }
        if configuration.microphoneDeviceID == nil {
            configuration.microphoneDeviceID = microphones.first?.id
        }
        installDeviceObservers()
        installLifecycleObservers()
        refreshEncoderPreflight()
        await recoverInterruptedFiles()
        await refreshLibrary()
        await updateCameraPreview()
    }

    func selectMode(_ mode: CaptureMode) {
        guard configuration.mode != mode else { return }
        if isChoosingScreen {
            picker.cancelPending()
            regionSelector.cancelPending()
        }
        if snapshot.phase == .selecting {
            Task { await engine.endSelection() }
        }
        configuration.applyDefaults(for: mode)
        if mode.needsCamera, configuration.cameraDeviceID == nil {
            configuration.cameraDeviceID = cameras.first?.id
        }
        if configuration.capturesMicrophone, configuration.microphoneDeviceID == nil {
            configuration.microphoneDeviceID = microphones.first?.id
        }
        if !mode.needsScreen {
            screenTarget = nil
            screenPreview = nil
            screenPreviewMessage = nil
            previewTask?.cancel()
        }
        Task { await updateCameraPreview() }
    }

    func setCameraDevice(_ id: String?) {
        configuration.cameraDeviceID = id
        Task { await updateCameraPreview() }
    }

    func setMicrophoneDevice(_ id: String?) {
        configuration.microphoneDeviceID = id
        Task { await updateCameraPreview() }
    }

    func setCapturesMicrophone(_ captures: Bool) {
        configuration.capturesMicrophone = captures
        Task { await updateCameraPreview() }
    }

    func setCapturesSystemAudio(_ captures: Bool) {
        configuration.capturesSystemAudio = captures
        Task { await updateCameraPreview() }
    }

    func setOverlayCorner(_ corner: OverlayCorner) {
        configuration.overlay.corner = corner
    }

    func setRecordsWindowContentOnly(_ enabled: Bool) {
        guard hasSelectedWindow else { return }
        if enabled {
            configuration.windowContentCrop = WindowContentCrop(
                topInsetPoints: min(
                    WindowContentCrop.defaultTopInsetPoints,
                    maximumWindowControlsHeightPoints
                )
            )
        } else {
            configuration.windowContentCrop = nil
        }
        startScreenPreview()
    }

    func setWindowControlsHeightPoints(_ height: Double) {
        guard hasSelectedWindow,
              configuration.windowContentCrop != nil else {
            return
        }
        configuration.windowContentCrop?.topInsetPoints = min(
            max(height, 40),
            maximumWindowControlsHeightPoints
        )
        startScreenPreview()
    }

    func chooseScreen(_ kind: ScreenSelectionKind) async {
        guard !isChoosingScreen else { return }
        isChoosingScreen = true
        defer { isChoosingScreen = false }

        errorMessage = nil
        do {
            guard await ensurePermission(.screen) else {
                throw RecorderError.permissionDenied(.screen)
            }
            await engine.beginSelection()
            let target: ScreenCaptureTarget
            switch kind.selectionRoute {
            case .contentSharingPicker:
                target = try await picker.pick(
                    kind: kind,
                    excludingBundleID: Bundle.main.bundleIdentifier
                )
            case .regionOverlay:
                let selection = try await regionSelector.selectRegion()
                let displayTarget = try await ScreenDisplayTargetResolver.resolve(
                    displayID: selection.displayID,
                    displayName: selection.displayName,
                    excludingBundleID: Bundle.main.bundleIdentifier
                )
                target = displayTarget.applying(
                    region: selection.rect,
                    displayID: selection.displayID,
                    displayName: selection.displayName
                )
            }
            guard configuration.mode.needsScreen else {
                throw RecorderError.cancelled
            }
            screenTarget = target
            configuration.windowContentCrop = nil
            configuration.screenSelection = target.selection
            await engine.endSelection()
            refreshPermissions()
            startScreenPreview()
            await updateCameraPreview()
        } catch RecorderError.cancelled {
            await engine.endSelection()
            return
        } catch {
            await engine.endSelection()
            errorMessage = error.localizedDescription
        }
    }

    func chooseFolder() async {
        let panel = NSOpenPanel()
        panel.title = "Choose a Recording Folder"
        panel.prompt = "Use This Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            folderAccess = try folderStore.save(url)
            folderURL = url
            await recoverInterruptedFiles()
            await refreshLibrary()
        } catch {
            errorMessage = "Local Recorder could not retain access to that folder: \(error.localizedDescription)"
        }
    }

    func requestPermission(_ kind: PermissionKind) async {
        errorMessage = nil
        let currentStatus = PrivacySettingsLink.resolvedStatus(
            system: PermissionService.status(for: kind),
            cached: permissions[kind]
        )
        permissions[kind] = currentStatus

        switch PrivacySettingsLink.grantAction(for: currentStatus) {
        case .openSettings:
            openPrivacySettings(for: kind)
            return
        case .none:
            await updateCameraPreview()
            return
        case .request:
            break
        }

        let granted = await PermissionService.request(kind)
        permissions[kind] = granted ? .authorized : .denied
        if !granted {
            errorMessage = "\(kind.title) access was not granted. You can enable it in System Settings → Privacy & Security."
            openPrivacySettings(for: kind)
        }
        await updateCameraPreview()
    }

    func openPrivacySettings(for kind: PermissionKind? = nil) {
        let url = kind.map(PrivacySettingsLink.url(for:)) ?? PrivacySettingsLink.root
        NSWorkspace.shared.open(url)
    }

    func startRecording() {
        guard canRecord, let folderURL else {
            errorMessage = firstReadinessMessage()
            return
        }
        errorMessage = nil
        noticeMessage = nil
        elapsedSeconds = 0
        recordingCameraPreview = nil
        isRecordingCameraPreviewVisible = true
        isChangingCombinedCamera = false
        recordTask?.cancel()
        recordTask = Task { [weak self] in
            guard let self else { return }
            await cameraPreview.stop()
            await microphoneMeter.stop()
            await systemAudioMeter.stop()
            do {
                try await engine.start(
                    RecordingRequest(
                        configuration: configuration,
                        screenTarget: screenTarget,
                        destinationFolder: folderURL
                    ),
                    countdown: 3
                )
            } catch RecorderError.cancelled {
                await updateCameraPreview()
            } catch {
                errorMessage = error.localizedDescription
                await updateCameraPreview()
            }
        }
    }

    func startOrStopFromHotKey() {
        switch snapshot.phase {
        case .recording, .paused:
            stopRecording()
        case .idle, .completed, .failed:
            if canRecord {
                selectedSection = .record
                NSApp.activate(ignoringOtherApps: true)
                controllerWindow.restoreMainWindow()
                startRecording()
            } else {
                NSApp.activate(ignoringOtherApps: true)
                controllerWindow.restoreMainWindow()
                errorMessage = firstReadinessMessage()
            }
        case .countingDown:
            Task { await engine.cancelCountdown() }
        case .selecting, .finalizing:
            break
        }
    }

    func cancelCountdown() {
        recordTask?.cancel()
        Task { await engine.cancelCountdown() }
    }

    func togglePause() {
        Task {
            if snapshot.phase == .recording {
                await engine.pause()
            } else if snapshot.phase == .paused {
                await engine.resume()
            }
        }
    }

    func toggleRecordingCameraPreview() {
        guard configuration.mode == .camera,
              [.recording, .paused].contains(snapshot.phase) else {
            return
        }
        isRecordingCameraPreviewVisible.toggle()
        controllerWindow.show(model: self)
    }

    func toggleCombinedRecordingCamera() {
        guard configuration.mode == .combined,
              [.recording, .paused].contains(snapshot.phase),
              !isChangingCombinedCamera else {
            return
        }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            "--ui-testing-combined-recording-controller"
        ) {
            snapshot.isCameraEnabled.toggle()
            controllerWindow.show(model: self)
            return
        }
#endif
        let enablesCamera = !snapshot.isCameraEnabled
        isChangingCombinedCamera = true
        Task { [weak self] in
            guard let self else { return }
            defer {
                isChangingCombinedCamera = false
            }
            do {
                try await engine.setCameraEnabled(enablesCamera)
            } catch {
                errorMessage = enablesCamera
                    ? "The camera could not be turned on: \(error.localizedDescription)"
                    : "The camera could not be turned off: \(error.localizedDescription)"
            }
        }
    }

    func stopRecording() {
        Task {
            do {
                _ = try await engine.stop()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func finishBeforeTermination() async {
        recordTask?.cancel()
        if snapshot.phase == .countingDown {
            await engine.cancelCountdown()
        } else if [.recording, .paused].contains(snapshot.phase) {
            _ = try? await engine.stop(message: "Recording finalized before quitting.")
        } else if snapshot.phase == .finalizing {
            while snapshot.phase == .finalizing {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func refreshLibrary() async {
        guard let folderURL else {
            recordings = []
            selectedRecording = nil
            return
        }
        do {
            recordings = try await library.recordings(in: folderURL)
            if let selectedRecording,
               !recordings.contains(where: { $0.url == selectedRecording.url }) {
                self.selectedRecording = nil
            }
        } catch {
            errorMessage = "The recording library could not be refreshed: \(error.localizedDescription)"
        }
    }

    func rename(_ artifact: RecordingArtifact, to name: String) async {
        do {
            selectedRecording = try await library.rename(artifact, to: name)
            await refreshLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveToTrash(_ artifact: RecordingArtifact) async {
        do {
            try await library.moveToTrash(artifact)
            if selectedRecording?.url == artifact.url {
                selectedRecording = nil
            }
            await refreshLibrary()
        } catch {
            errorMessage = "The recording could not be moved to Trash: \(error.localizedDescription)"
        }
    }

    func reveal(_ artifact: RecordingArtifact) {
        NSWorkspace.shared.activateFileViewerSelecting([artifact.url])
    }

    func discardInvalidRecoveryFiles() async {
        await recovery.discard(invalidRecoveryFiles)
        invalidRecoveryFiles = []
    }

    private func apply(_ snapshot: RecordingSnapshot) {
        let oldPhase = self.snapshot.phase
        self.snapshot = snapshot
        if let message = snapshot.message {
            noticeMessage = message
        }

        switch snapshot.phase {
        case .recording:
            if oldPhase != .paused {
                startElapsedTimerIfNeeded()
            }
            controllerWindow.show(model: self)
        case .paused, .finalizing:
            controllerWindow.show(model: self)
        case .completed:
            timerTask?.cancel()
            recordingCameraPreview = nil
            isRecordingCameraPreviewVisible = true
            isChangingCombinedCamera = false
            controllerWindow.closeAndRestore()
            Task {
                await refreshLibrary()
                await updateCameraPreview()
            }
        case .failed:
            timerTask?.cancel()
            recordingCameraPreview = nil
            isRecordingCameraPreviewVisible = true
            isChangingCombinedCamera = false
            controllerWindow.closeAndRestore()
            errorMessage = snapshot.message
            Task { await updateCameraPreview() }
        case .idle:
            timerTask?.cancel()
            elapsedSeconds = 0
            recordingCameraPreview = nil
            isRecordingCameraPreviewVisible = true
            isChangingCombinedCamera = false
            controllerWindow.closeAndRestore()
            Task { await updateCameraPreview() }
        case .selecting, .countingDown:
            break
        }
    }

    private func applyRecordingPreview(
        _ frame: RecordingPreviewFrame
    ) {
        guard configuration.mode == .camera,
              isRecordingCameraPreviewVisible,
              [.recording, .paused].contains(snapshot.phase) else {
            return
        }
        let source = CIImage(cvPixelBuffer: frame.pixelBuffer)
        guard !source.extent.isEmpty else { return }
        let scale = min(
            1,
            640 / source.extent.width,
            360 / source.extent.height
        )
        let image = source.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        guard let cgImage = recordingPreviewContext.createCGImage(
            image,
            from: image.extent.integral
        ) else {
            return
        }
        recordingCameraPreview = NSImage(
            cgImage: cgImage,
            size: NSSize(
                width: cgImage.width,
                height: cgImage.height
            )
        )
    }

    private func startElapsedTimerIfNeeded() {
        guard timerTask == nil || timerTask?.isCancelled == true else { return }
        if elapsedSeconds == 0 {
            elapsedSeconds = 0
        }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if snapshot.phase == .recording {
                    elapsedSeconds += 1
                }
            }
        }
    }

    private func refreshDevices() {
        cameras = DeviceCatalog.cameras()
        microphones = DeviceCatalog.microphones()
        if let selected = configuration.cameraDeviceID,
           !cameras.contains(where: { $0.id == selected }) {
            configuration.cameraDeviceID = cameras.first?.id
        }
        if let selected = configuration.microphoneDeviceID,
           !microphones.contains(where: { $0.id == selected }) {
            configuration.microphoneDeviceID = microphones.first?.id
        }
    }

    private func refreshEncoderPreflight() {
        if configuration.mode.needsCamera,
           let cameraIssue = DeviceCatalog.highQualityCameraFailureReason(
               deviceID: configuration.cameraDeviceID
           ) {
            highQualityIssue = cameraIssue
            return
        }

        let sourceSize: CGSize
        if configuration.mode.needsScreen {
            guard let screenTarget = resolvedScreenTarget else {
                highQualityIssue = nil
                return
            }
            sourceSize = screenTarget.pixelSize
        } else {
            if let preferred = DeviceCatalog.preferredCameraCaptureSize(
                deviceID: configuration.cameraDeviceID,
                preset: .high
            ) {
                sourceSize = preferred
            } else {
                let device = configuration.cameraDeviceID.flatMap(
                    AVCaptureDevice.init(uniqueID:)
                )
                    ?? AVCaptureDevice.systemPreferredCamera
                    ?? AVCaptureDevice.default(for: .video)
                guard let device else {
                    highQualityIssue = nil
                    return
                }
                let dimensions = CMVideoFormatDescriptionGetDimensions(
                    device.activeFormat.formatDescription
                )
                sourceSize = CGSize(
                    width: Int(dimensions.width),
                    height: Int(dimensions.height)
                )
            }
        }
        let outputSize = OutputGeometry.outputSize(
            sourceSize: sourceSize,
            preset: .high,
            cameraOnly: configuration.mode == .camera
        )
        highQualityIssue = EncoderPreflight.highQualityFailureReason(
            outputSize: outputSize
        )
    }

    private func refreshPermissions() {
        for kind in PermissionKind.allCases {
            permissions[kind] = PrivacySettingsLink.resolvedStatus(
                system: PermissionService.status(for: kind),
                cached: permissions[kind]
            )
        }
    }

    private func ensurePermission(_ kind: PermissionKind) async -> Bool {
        refreshPermissions()
        if permissions[kind] == .authorized { return true }
        let granted = await PermissionService.request(kind)
        permissions[kind] = granted ? .authorized : .denied
        return granted
    }

    private func updateCameraPreview() async {
        if isUITesting {
            microphoneLevel = 0
            systemAudioLevel = 0
            return
        }
        let isPreviewing = [.idle, .completed, .failed].contains(snapshot.phase)
        if configuration.mode.needsCamera,
           permissions[.camera] == .authorized,
           isPreviewing {
            do {
                try await cameraPreview.start(deviceID: configuration.cameraDeviceID)
            } catch {
                errorMessage = "Camera preview failed: \(error.localizedDescription)"
            }
        } else {
            await cameraPreview.stop()
        }

        if configuration.capturesMicrophone,
           permissions[.microphone] == .authorized,
           isPreviewing {
            do {
                try await microphoneMeter.start(
                    deviceID: configuration.microphoneDeviceID
                ) { [weak self] level in
                    Task { @MainActor [weak self] in
                        self?.microphoneLevel = level
                    }
                }
            } catch {
                microphoneLevel = 0
            }
        } else {
            await microphoneMeter.stop()
            microphoneLevel = 0
        }

        if configuration.mode.needsScreen,
           configuration.capturesSystemAudio,
           permissions[.screen] == .authorized,
           isPreviewing,
           let screenTarget {
            do {
                try await systemAudioMeter.start(target: screenTarget) {
                    [weak self] level in
                    Task { @MainActor [weak self] in
                        self?.systemAudioLevel = level
                    }
                }
            } catch {
                systemAudioLevel = 0
            }
        } else {
            await systemAudioMeter.stop()
            systemAudioLevel = 0
        }
    }

    private func startScreenPreview() {
        previewTask?.cancel()
        screenPreviewGeneration = UUID()
        let generation = screenPreviewGeneration
        guard let target = resolvedScreenTarget else {
            screenPreview = nil
            screenPreviewMessage = nil
            return
        }
        screenPreview = nil
        screenPreviewMessage = "Loading preview…"
        let provider = screenPreviewProvider
        previewTask = Task { [weak self, target] in
            while !Task.isCancelled {
                guard let self else { return }
                if [.idle, .completed, .failed, .countingDown].contains(snapshot.phase) {
                    do {
                        let image = try await provider(
                            target,
                            configuration.showsCursor
                        )
                        try Task.checkCancellation()
                        guard screenPreviewGeneration == generation else {
                            return
                        }
                        screenPreview = NSImage(
                            cgImage: image,
                            size: target.pointSize
                        )
                        screenPreviewMessage = nil
                    } catch is CancellationError {
                        return
                    } catch {
                        guard screenPreviewGeneration == generation else {
                            return
                        }
                        screenPreview = nil
                        screenPreviewMessage =
                            "Preview unavailable. Retrying…"
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func recoverInterruptedFiles() async {
        guard let folderURL else { return }
        let report = await recovery.recover(in: folderURL)
        invalidRecoveryFiles = report.invalid
        if !report.recovered.isEmpty {
            noticeMessage = "\(report.recovered.count) interrupted recording(s) were recovered."
        }
    }

    private func installDeviceObservers() {
        guard deviceObservers.isEmpty else { return }
        for name in [
            AVCaptureDevice.wasConnectedNotification,
            AVCaptureDevice.wasDisconnectedNotification
        ] {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshDevices()
                    await self?.updateCameraPreview()
                }
            }
            deviceObservers.append(observer)
        }
        let activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPermissions()
                await self?.updateCameraPreview()
            }
        }
        deviceObservers.append(activationObserver)
    }

    private func installLifecycleObservers() {
        guard workspaceObservers.isEmpty else { return }

        let notifications: [(Notification.Name, String)] = [
            (
                NSWorkspace.willSleepNotification,
                "The Mac is going to sleep. The playable recording was preserved."
            ),
            (
                NSWorkspace.screensDidSleepNotification,
                "The displays went to sleep. The playable recording was preserved."
            ),
            (
                NSWorkspace.sessionDidResignActiveNotification,
                "The login session became inactive. The playable recording was preserved."
            )
        ]
        for (name, message) in notifications {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.finalizeForSystemInterruption(message)
                }
            }
            workspaceObservers.append(observer)
        }
    }

    private func finalizeForSystemInterruption(_ message: String) {
        switch snapshot.phase {
        case .countingDown:
            cancelCountdown()
            noticeMessage = "Recording was cancelled because capture became unavailable."
        case .recording, .paused:
            Task {
                do {
                    _ = try await engine.stop(message: message)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case .idle, .selecting, .finalizing, .completed, .failed:
            break
        }
    }

    private func firstReadinessMessage() -> String {
        if folderURL == nil {
            return "Choose a recording folder before starting."
        }
        if let issue = configuration.validationIssues(
            hasResolvedScreenTarget: screenTarget != nil
        ).first {
            return issue.message
        }
        if configuration.mode.needsScreen, permissions[.screen] != .authorized {
            return "Grant Screen Recording access before starting."
        }
        if configuration.mode.needsCamera, permissions[.camera] != .authorized {
            return "Grant Camera access before starting."
        }
        if configuration.capturesMicrophone, permissions[.microphone] != .authorized {
            return "Grant Microphone access or turn microphone recording off."
        }
        if configuration.quality == .high, let highQualityIssue {
            return highQualityIssue
        }
        return "Check the recording configuration before starting."
    }

    private func persistSettings() {
        guard !isUITesting else { return }
        var stored = configuration
        stored.screenSelection = nil
        stored.windowContentCrop = nil
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: "recordingConfiguration")
        }
    }

    private static func loadSettings() -> RecordingConfiguration {
        guard let data = UserDefaults.standard.data(forKey: "recordingConfiguration"),
              var settings = try? JSONDecoder().decode(RecordingConfiguration.self, from: data) else {
            return RecordingConfiguration()
        }
        settings.screenSelection = nil
        settings.windowContentCrop = nil
        return settings
    }

    private static func makeScreenPreviewProvider() -> ScreenPreviewProvider {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            "--ui-testing-window-content"
        ) {
            return { _, _ in
                await Task.yield()
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                guard let context = CGContext(
                    data: nil,
                    width: 16,
                    height: 9,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else {
                    throw RecorderError.captureFailed(
                        "Could not create the UI test preview."
                    )
                }
                context.setFillColor(
                    CGColor(
                        red: 0.12,
                        green: 0.32,
                        blue: 0.58,
                        alpha: 1
                    )
                )
                context.fill(
                    CGRect(x: 0, y: 0, width: 16, height: 9)
                )
                guard let image = context.makeImage() else {
                    throw RecorderError.captureFailed(
                        "Could not render the UI test preview."
                    )
                }
                return image
            }
        }
#endif
        return { target, showsCursor in
            try await ScreenPreviewService.image(
                for: target,
                showsCursor: showsCursor
            )
        }
    }

    private var resolvedScreenTarget: ScreenCaptureTarget? {
        screenTarget?.applying(
            windowContentCrop: configuration.windowContentCrop
        )
    }

#if DEBUG
    private func bootstrapForUITestingIfNeeded() async -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        let isControllerTest = arguments.contains(
            "--ui-testing-recording-controller"
        )
        let isCombinedControllerTest = arguments.contains(
            "--ui-testing-combined-recording-controller"
        )
        let isSelecting = arguments.contains("--ui-testing-selecting")
        let isWindowContentTest = arguments.contains(
            "--ui-testing-window-content"
        )
        let isReady = arguments.contains("--ui-testing-ready")
            || isControllerTest
            || isCombinedControllerTest
            || isSelecting
            || isWindowContentTest
        let isUnready = arguments.contains("--ui-testing-unready")
        guard isReady || isUnready else { return false }

        configuration = RecordingConfiguration(
            mode: isSelecting || isWindowContentTest
                ? .screen
                : (isCombinedControllerTest ? .combined : .camera),
            cameraDeviceID: "ui-test-camera",
            microphoneDeviceID: "ui-test-microphone",
            capturesSystemAudio: false,
            capturesMicrophone: false,
            quality: .standard
        )
        cameras = [
            CaptureDeviceDescriptor(
                id: "ui-test-camera",
                name: "UI Test Camera",
                kind: .camera,
                isSystemPreferred: true
            )
        ]
        microphones = [
            CaptureDeviceDescriptor(
                id: "ui-test-microphone",
                name: "UI Test Microphone",
                kind: .microphone,
                isSystemPreferred: true
            )
        ]
        for kind in PermissionKind.allCases {
            permissions[kind] = isReady ? .authorized : .notDetermined
        }
        screenTarget = nil
        screenPreview = nil
        highQualityIssue = nil
        if isWindowContentTest {
            let target = ScreenCaptureTarget(
                selection: .window(
                    id: 42,
                    title: "New Tab — Google Chrome"
                ),
                contentPointSize: CGSize(width: 1_300, height: 864),
                pointPixelScale: 2
            )
            screenTarget = target
            configuration.screenSelection = target.selection
            startScreenPreview()
        }

        guard isReady else {
            folderURL = nil
            recordings = []
            return true
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LocalRecorderUITests-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        let fixtureURL = folder.appendingPathComponent(
            "UI Fixture.mp4"
        )
        if !FileManager.default.fileExists(atPath: fixtureURL.path) {
            _ = FileManager.default.createFile(
                atPath: fixtureURL.path,
                contents: Data()
            )
        }
        folderURL = folder
        recordings = [
            RecordingArtifact(
                url: fixtureURL,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                duration: 42,
                fileSize: 1_024
            )
        ]
        if isControllerTest || isCombinedControllerTest {
            let fixture = CIImage(
                color: CIColor(
                    red: 0.12,
                    green: 0.32,
                    blue: 0.58
                )
            )
            .cropped(
                to: CGRect(x: 0, y: 0, width: 640, height: 360)
            )
            if let cgImage = recordingPreviewContext.createCGImage(
                fixture,
                from: fixture.extent
            ) {
                recordingCameraPreview = NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: 640, height: 360)
                )
            }
            snapshot = RecordingSnapshot(
                phase: .recording,
                isCameraEnabled: true
            )
            elapsedSeconds = 7
            isRecordingCameraPreviewVisible = true
            controllerWindow.show(model: self)
        }
        if isSelecting {
            await engine.beginSelection()
            snapshot = await engine.currentSnapshot()
        }
        return true
    }
#endif
}

enum AppSection: String, CaseIterable, Identifiable {
    case record
    case library
    case settings

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .record: "record.circle"
        case .library: "film.stack"
        case .settings: "gearshape"
        }
    }
}
