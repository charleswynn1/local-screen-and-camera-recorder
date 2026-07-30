@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public struct LiveRecordingPipelineFactory: RecordingPipelineFactory {
    public init() {}

    public func makePipeline(for request: RecordingRequest) throws -> any RecordingPipeline {
        let issues = request.configuration.validationIssues(
            hasResolvedScreenTarget: request.screenTarget != nil
        )
        if let issue = issues.first {
            throw RecorderError.invalidConfiguration(issue.message)
        }

        let sourceSize: CGSize
        if request.configuration.mode.needsScreen {
            guard let target = request.screenTarget else {
                throw RecorderError.invalidConfiguration(ConfigurationIssue.missingScreenSelection.message)
            }
            sourceSize = target.pixelSize
        } else {
            sourceSize = Self.cameraSourceSize(
                deviceID: request.configuration.cameraDeviceID,
                preset: request.configuration.quality
            )
        }
        let outputSize = OutputGeometry.outputSize(
            sourceSize: sourceSize,
            preset: request.configuration.quality,
            cameraOnly: request.configuration.mode == .camera
        )
        guard outputSize.width >= 2, outputSize.height >= 2 else {
            throw RecorderError.invalidConfiguration(ConfigurationIssue.invalidOutputSize.message)
        }

        let writer = try AssetRecordingWriter(
            destinationFolder: request.destinationFolder,
            outputSize: outputSize,
            preset: request.configuration.quality,
            includesAudio: request.configuration.capturesSystemAudio
                || request.configuration.capturesMicrophone
        )
        return try LiveRecordingPipeline(
            request: request,
            outputSize: outputSize,
            screenSource: ScreenCaptureService(),
            cameraSource: AVCameraCaptureService(),
            microphoneSource: AVMicrophoneCaptureService(),
            compositor: MetalVideoCompositor(),
            audioMixer: PCMAudioMixer(
                includesSystemAudio: request.configuration.capturesSystemAudio,
                includesMicrophone: request.configuration.capturesMicrophone
            ),
            writer: writer
        )
    }

    private static func cameraSourceSize(
        deviceID: String?,
        preset: QualityPreset
    ) -> CGSize {
        if let preferred = DeviceCatalog.preferredCameraCaptureSize(
            deviceID: deviceID,
            preset: preset
        ) {
            return preferred
        }
        let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:))
            ?? AVCaptureDevice.systemPreferredCamera
            ?? AVCaptureDevice.default(for: .video)
        guard let device else { return CGSize(width: 1_920, height: 1_080) }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard dimensions.width > 0, dimensions.height > 0 else {
            return CGSize(width: 1_920, height: 1_080)
        }
        return CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
    }
}

public final class LiveRecordingPipeline: RecordingPipeline, @unchecked Sendable {
    public let events: AsyncStream<PipelineEvent>
    public let previewFrames: AsyncStream<RecordingPreviewFrame>

    private let eventContinuation: AsyncStream<PipelineEvent>.Continuation
    private let previewContinuation:
        AsyncStream<RecordingPreviewFrame>.Continuation
    private let request: RecordingRequest
    private let outputSize: CGSize
    private let screenSource: any ScreenSource
    private let cameraSource: any CameraSource
    private let microphoneSource: any MicrophoneSource
    private let compositor: any VideoCompositor
    private let audioMixer: any AudioMixer
    private let writer: any RecordingWriter
    private let diskSpaceChecker: any DiskSpaceChecking
    private let diskMonitorInterval: Duration
    private let processingQueue = DispatchQueue(
        label: "com.charleswynn.localrecorder.pipeline",
        qos: .userInteractive
    )
    private let enqueueLock = NSLock()
    private let timeline: TimelineNormalizer
    private var latestCameraBuffer: CVPixelBuffer?
    private var isAcceptingSamples = false
    private var isPaused = false
    private var audioFailureReported = false
    private var writerFailureReported = false
    private var screenFramePending = false
    private var cameraFramePending = false
    private var pendingAudioSamples = 0
    private var audioBackpressureReported = false
    private let maximumPendingAudioSamples = 32
    private var lastPreviewPresentationTime: CMTime?
    private let previewInterval = CMTime(value: 1, timescale: 10)
    private var diskMonitor: Task<Void, Never>?

    public init(
        request: RecordingRequest,
        outputSize: CGSize,
        screenSource: any ScreenSource,
        cameraSource: any CameraSource,
        microphoneSource: any MicrophoneSource,
        compositor: any VideoCompositor,
        audioMixer: any AudioMixer,
        writer: any RecordingWriter,
        diskSpaceChecker: any DiskSpaceChecking = VolumeDiskSpaceChecker(),
        diskMonitorInterval: Duration = .seconds(5)
    ) throws {
        self.request = request
        self.outputSize = outputSize
        self.screenSource = screenSource
        self.cameraSource = cameraSource
        self.microphoneSource = microphoneSource
        self.compositor = compositor
        self.audioMixer = audioMixer
        self.writer = writer
        self.diskSpaceChecker = diskSpaceChecker
        self.diskMonitorInterval = diskMonitorInterval
        timeline = TimelineNormalizer(epoch: .zero)
        (events, eventContinuation) = AsyncStream.makeStream()
        (previewFrames, previewContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    public func prepare() async throws {
        let values = try request.destinationFolder.resourceValues(
            forKeys: [.isDirectoryKey, .isWritableKey]
        )
        guard values.isDirectory == true, values.isWritable != false else {
            throw RecorderError.destinationUnavailable
        }
        if let capacity = diskSpaceChecker.availableCapacity(
            at: request.destinationFolder
        ), capacity < 500_000_000 {
            throw RecorderError.writerFailed("At least 500 MB of free disk space is required to begin.")
        }
    }

    public func start() async throws {
        let epoch = CMClockGetTime(CMClockGetHostTimeClock())
        timeline.reset(epoch: epoch)
        try writer.start()
        processingQueue.sync {
            isAcceptingSamples = true
            isPaused = false
        }

        do {
            if request.configuration.mode.needsScreen {
                guard let target = request.screenTarget else {
                    throw RecorderError.invalidConfiguration(ConfigurationIssue.missingScreenSelection.message)
                }
                try await screenSource.start(
                    target: target,
                    configuration: ScreenSourceConfiguration(
                        outputSize: outputSize,
                        framesPerSecond: request.configuration.quality.framesPerSecond,
                        capturesSystemAudio: request.configuration.capturesSystemAudio,
                        showsCursor: request.configuration.showsCursor,
                        showsMouseClicks: request.configuration.showsMouseClicks
                    ),
                    videoHandler: { [weak self] in self?.enqueueScreen($0) },
                    audioHandler: { [weak self] in self?.enqueueAudio($0) },
                    eventHandler: { [weak self] in self?.handleSourceEvent($0) }
                )
            }

            if request.configuration.mode.needsCamera {
                try await cameraSource.start(
                    cameraDeviceID: request.configuration.cameraDeviceID,
                    maximumVideoSize: request.configuration.quality.maximumSize,
                    framesPerSecond: request.configuration.quality.framesPerSecond,
                    videoHandler: { [weak self] in self?.enqueueCamera($0) },
                    eventHandler: { [weak self] in self?.handleSourceEvent($0) }
                )
            }
            if request.configuration.capturesMicrophone {
                try await microphoneSource.start(
                    microphoneDeviceID: request.configuration.microphoneDeviceID,
                    audioHandler: { [weak self] in self?.enqueueAudio($0) },
                    eventHandler: { [weak self] in self?.handleSourceEvent($0) }
                )
            }
        } catch {
            await screenSource.stop()
            await cameraSource.stop()
            await microphoneSource.stop()
            writer.cancel()
            throw error
        }
        startDiskMonitor()
    }

    public func pause() async {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        processingQueue.sync {
            guard isAcceptingSamples, !isPaused else { return }
            isPaused = true
            timeline.pause(at: now)
        }
    }

    public func resume() async {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        processingQueue.sync {
            guard isAcceptingSamples, isPaused else { return }
            timeline.resume(at: now)
            isPaused = false
        }
    }

    public func stop() async throws -> URL {
        diskMonitor?.cancel()
        diskMonitor = nil
        await screenSource.stop()
        await cameraSource.stop()
        await microphoneSource.stop()

        try processingQueue.sync {
            isAcceptingSamples = false
            for sample in try audioMixer.finish() {
                _ = writer.appendAudio(sample)
            }
        }
        let url = try await writer.finish()
        eventContinuation.finish()
        previewContinuation.finish()
        return url
    }

    public func cancel() async {
        diskMonitor?.cancel()
        diskMonitor = nil
        processingQueue.sync {
            isAcceptingSamples = false
        }
        await screenSource.stop()
        await cameraSource.stop()
        await microphoneSource.stop()
        writer.cancel()
        eventContinuation.finish()
        previewContinuation.finish()
    }

    private func enqueueScreen(_ sample: VideoSample) {
        guard enqueueLock.withLock({
            guard !screenFramePending else { return false }
            screenFramePending = true
            return true
        }) else {
            return
        }
        processingQueue.async { [weak self] in
            guard let self else { return }
            defer {
                enqueueLock.withLock {
                    screenFramePending = false
                }
            }
            guard isAcceptingSamples, !isPaused else { return }
            render(
                screen: CMSampleBufferGetImageBuffer(sample.sampleBuffer),
                camera: request.configuration.mode == .combined ? latestCameraBuffer : nil,
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sample.sampleBuffer)
            )
        }
    }

    private func enqueueCamera(_ sample: VideoSample) {
        guard enqueueLock.withLock({
            guard !cameraFramePending else { return false }
            cameraFramePending = true
            return true
        }) else {
            return
        }
        processingQueue.async { [weak self] in
            guard let self else { return }
            defer {
                enqueueLock.withLock {
                    cameraFramePending = false
                }
            }
            guard isAcceptingSamples, !isPaused,
                  let camera = CMSampleBufferGetImageBuffer(sample.sampleBuffer) else { return }
            if request.configuration.mode == .camera {
                render(
                    screen: nil,
                    camera: camera,
                    presentationTime: CMSampleBufferGetPresentationTimeStamp(sample.sampleBuffer)
                )
            } else {
                latestCameraBuffer = camera
            }
        }
    }

    private func enqueueAudio(_ sample: AudioSample) {
        let accepted = enqueueLock.withLock {
            guard pendingAudioSamples < maximumPendingAudioSamples else {
                if !audioBackpressureReported {
                    audioBackpressureReported = true
                    eventContinuation.yield(
                        .warning("Audio input briefly exceeded real-time capacity; late samples were dropped.")
                    )
                }
                return false
            }
            pendingAudioSamples += 1
            return true
        }
        guard accepted else { return }

        processingQueue.async { [weak self] in
            guard let self else { return }
            defer {
                enqueueLock.withLock {
                    pendingAudioSamples = max(0, pendingAudioSamples - 1)
                    if pendingAudioSamples < maximumPendingAudioSamples / 2 {
                        audioBackpressureReported = false
                    }
                }
            }
            guard isAcceptingSamples, !isPaused else { return }
            do {
                let sourceTime = CMSampleBufferGetPresentationTimeStamp(sample.sampleBuffer)
                let normalized = timeline.normalized(sourceTime)
                for mixed in try audioMixer.ingest(sample, normalizedPTS: normalized) {
                    let appended = writer.appendAudio(mixed)
                    if !appended {
                        reportWriterFailureIfNeeded()
                    }
                }
            } catch {
                if !audioFailureReported {
                    audioFailureReported = true
                    eventContinuation.yield(
                        .warning("Audio processing stopped: \(error.localizedDescription)")
                    )
                }
            }
        }
    }

    private func render(
        screen: CVPixelBuffer?,
        camera: CVPixelBuffer?,
        presentationTime: CMTime
    ) {
        guard let pool = writer.pixelBufferPool else {
            eventContinuation.yield(.fatal(RecorderError.noPixelBufferPool.localizedDescription))
            return
        }
        do {
            let frame = try compositor.render(
                screen: screen,
                camera: camera,
                mode: request.configuration.mode,
                overlay: request.configuration.overlay,
                outputSize: outputSize,
                pool: pool
            )
            let appended = writer.appendVideo(
                frame,
                at: timeline.normalized(presentationTime)
            )
            publishCameraPreview(
                frame,
                sourcePresentationTime: presentationTime
            )
            if !appended {
                reportWriterFailureIfNeeded()
            }
        } catch {
            eventContinuation.yield(.fatal(error.localizedDescription))
        }
    }

    private func publishCameraPreview(
        _ frame: CVPixelBuffer,
        sourcePresentationTime: CMTime
    ) {
        guard request.configuration.mode == .camera else { return }
        if let lastPreviewPresentationTime {
            let interval = CMTimeSubtract(
                sourcePresentationTime,
                lastPreviewPresentationTime
            )
            if interval.isNumeric,
               interval >= .zero,
               interval < previewInterval {
                return
            }
        }
        lastPreviewPresentationTime = sourcePresentationTime
        previewContinuation.yield(
            RecordingPreviewFrame(
                pixelBuffer: frame,
                presentationTime: timeline.normalized(
                    sourcePresentationTime
                )
            )
        )
    }

    private func reportWriterFailureIfNeeded() {
        guard !writerFailureReported, let failure = writer.failure else { return }
        writerFailureReported = true
        eventContinuation.yield(.fatal(failure.localizedDescription))
    }

    private func handleSourceEvent(_ event: PipelineEvent) {
        if case let .stopRequested(message) = event,
           request.configuration.mode == .combined,
           message.localizedCaseInsensitiveContains("camera") {
            processingQueue.async { [weak self] in
                self?.latestCameraBuffer = nil
            }
            eventContinuation.yield(.warning("\(message) Screen recording is continuing."))
            return
        }
        eventContinuation.yield(event)
    }

    private func startDiskMonitor() {
        let folder = request.destinationFolder
        let continuation = eventContinuation
        let checker = diskSpaceChecker
        let interval = diskMonitorInterval
        diskMonitor = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                if let capacity = checker.availableCapacity(at: folder),
                   capacity < 250_000_000 {
                    continuation.yield(
                        .stopRequested("Disk space is critically low. The recording is being finalized.")
                    )
                    return
                }
            }
        }
    }
}

public struct VolumeDiskSpaceChecker: DiskSpaceChecking {
    public init() {}

    public func availableCapacity(at folder: URL) -> Int64? {
        let values = try? folder.resourceValues(
            forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ]
        )
        if let important = values?.volumeAvailableCapacityForImportantUsage,
           important > 0 {
            return important
        }
        if let fallback = values?.volumeAvailableCapacity,
           fallback > 0 {
            return Int64(fallback)
        }
        return nil
    }
}
