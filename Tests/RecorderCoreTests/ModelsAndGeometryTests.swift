import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
@preconcurrency import ScreenCaptureKit
@testable import RecorderCore
import Testing

@Suite("RecorderCore test plan", .serialized)
struct RecorderCoreTestPlan {}

extension RecorderCoreTestPlan {
@Suite("Models and geometry")
struct ModelsAndGeometryTests {
    @Test
    func regionSelectionBypassesTheFullDisplaySharingPicker() {
        #expect(
            ScreenSelectionKind.display.selectionRoute
                == .contentSharingPicker
        )
        #expect(
            ScreenSelectionKind.window.selectionRoute
                == .contentSharingPicker
        )
        #expect(
            ScreenSelectionKind.region.selectionRoute
                == .regionOverlay
        )
    }

    @Test
    @MainActor
    func screenPickerCancellationCallbackCanArriveOffMainExecutor() async {
        let picker = ScreenContentPicker()
        let callbackRanOffMain = await Task.detached {
            let ranOffMain = pthread_main_np() == 0
            picker.contentSharingPicker(
                SCContentSharingPicker.shared,
                didCancelFor: nil
            )
            return ranOffMain
        }.value

        #expect(callbackRanOffMain)
        await Task.yield()
    }

    @Test
    func permissionGrantRoutesFirstRequestAndDeniedRecoveryDifferently() {
        #expect(PrivacySettingsLink.grantAction(for: .notDetermined) == .request)
        #expect(PrivacySettingsLink.grantAction(for: .denied) == .openSettings)
        #expect(PrivacySettingsLink.grantAction(for: .restricted) == .openSettings)
        #expect(PrivacySettingsLink.grantAction(for: .authorized) == .none)
        #expect(
            PrivacySettingsLink.resolvedStatus(
                system: .notDetermined,
                cached: .denied
            ) == .denied
        )
        #expect(
            PrivacySettingsLink.resolvedStatus(
                system: .authorized,
                cached: .denied
            ) == .authorized
        )
    }

    @Test
    func privacySettingsLinksTargetEachPermissionToggle() {
        #expect(
            PrivacySettingsLink.root.absoluteString
                == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        )
        #expect(
            PrivacySettingsLink.url(for: .screen).absoluteString
                == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        )
        #expect(
            PrivacySettingsLink.url(for: .camera).absoluteString
                == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera"
        )
        #expect(
            PrivacySettingsLink.url(for: .microphone).absoluteString
                == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
        )
    }

    @Test
    func captureSessionCommitsConfigurationBeforeStarting() {
        let session = CaptureSessionLifecycleSpy()

        let configuredDevice = CaptureSessionTransaction
            .configureAndStart(session) {
                session.recordConfiguration()
                return "microphone"
            }

        #expect(configuredDevice == "microphone")
        #expect(
            session.events
                == [.beginConfiguration, .configure, .commitConfiguration, .start]
        )
        #expect(!session.startedWhileConfiguring)
    }

    @Test
    func captureSessionCommitsAndDoesNotStartAfterConfigurationFailure() {
        let session = CaptureSessionLifecycleSpy()

        #expect(throws: CaptureSessionLifecycleTestError.self) {
            try CaptureSessionTransaction.configureAndStart(session) {
                session.recordConfiguration()
                throw CaptureSessionLifecycleTestError.configurationFailed
            }
        }

        #expect(
            session.events
                == [.beginConfiguration, .configure, .commitConfiguration]
        )
        #expect(!session.startedWhileConfiguring)
    }

    @Test
    func regionConversionUsesTopLeftCaptureCoordinates() {
        let result = NormalizedRect.from(
            displayLocalAppKitRect: CGRect(x: 100, y: 50, width: 400, height: 300),
            displaySize: CGSize(width: 1_000, height: 800)
        )

        #expect(abs(result.x - 0.1) < 0.000_001)
        #expect(abs(result.y - 0.5625) < 0.000_001)
        #expect(abs(result.width - 0.4) < 0.000_001)
        #expect(abs(result.height - 0.375) < 0.000_001)
        #expect(result.isValid)
    }

    @Test
    func regionClampsToOneDisplay() {
        let result = NormalizedRect(x: -0.2, y: 0.8, width: 1.4, height: 0.5).clamped()

        #expect(result.x == 0)
        #expect(abs(result.y - 0.8) < 0.000_001)
        #expect(result.width == 1)
        #expect(abs(result.height - 0.2) < 0.000_001)
        #expect(result.isValid)
    }

    @Test
    func retinaRegionConvertsDisplayLocalPointsToPixels() {
        let region = NormalizedRect(x: 0.1, y: 0.25, width: 0.5, height: 0.5)
        let pixels = region.denormalizedInPixels(
            displayPointSize: CGSize(width: 1_512, height: 982),
            pointPixelScale: 2
        )

        #expect(abs(pixels.minX - 302.4) < 0.001)
        #expect(abs(pixels.minY - 491) < 0.001)
        #expect(abs(pixels.width - 1_512) < 0.001)
        #expect(abs(pixels.height - 982) < 0.001)
    }

    @Test
    func cameraOnlyUsesLargestNonUpscaledSixteenByNineCanvas() {
        #expect(
            OutputGeometry.outputSize(
                sourceSize: CGSize(width: 640, height: 480),
                preset: .standard,
                cameraOnly: true
            ) == CGSize(width: 640, height: 360)
        )
    }

    @Test
    func screenOutputPreservesAspectRatioAndEvenDimensions() {
        let source = CGSize(width: 3_456, height: 2_234)
        let output = OutputGeometry.outputSize(sourceSize: source, preset: .standard)

        #expect(output.width <= 1_920)
        #expect(output.height <= 1_080)
        #expect(Int(output.width) % 2 == 0)
        #expect(Int(output.height) % 2 == 0)
        #expect(abs(output.width / output.height - source.width / source.height) < 0.003)
    }

    @Test
    func webContentCropRemovesBrowserControlsFromPreviewAndRecordingGeometry() {
        let rawTarget = ScreenCaptureTarget(
            selection: .window(
                id: 42,
                title: "New Tab — Google Chrome"
            ),
            contentPointSize: CGSize(width: 1_300, height: 864),
            pointPixelScale: 2
        )
        let configuration = RecordingConfiguration(
            mode: .screen,
            screenSelection: rawTarget.selection,
            capturesSystemAudio: false,
            capturesMicrophone: false,
            windowContentCrop: WindowContentCrop(
                topInsetPoints: 120
            )
        )
        let request = RecordingRequest(
            configuration: configuration,
            screenTarget: rawTarget,
            destinationFolder: URL(fileURLWithPath: "/tmp")
        )

        let target = request.resolvedScreenTarget
        #expect(target != nil)
        #expect(target?.capturePointSize == CGSize(width: 1_300, height: 864))
        #expect(target?.pointSize == CGSize(width: 1_300, height: 744))
        #expect(target?.pixelSize == CGSize(width: 2_600, height: 1_488))

        let outputSize = OutputGeometry.outputSize(
            sourceSize: target?.pixelSize ?? .zero,
            preset: .standard
        )
        let captureSize = target?.captureOutputSize(
            for: outputSize
        ) ?? .zero
        let cropRect = target?.outputCrop?
            .denormalizedFromTopLeft(
                inBottomLeftCoordinatesOf: CGRect(
                    origin: .zero,
                    size: captureSize
                )
            ) ?? .zero

        #expect(captureSize.height > outputSize.height)
        #expect(abs(cropRect.minY) < 0.001)
        #expect(abs(cropRect.width - outputSize.width) < 3)
        #expect(abs(cropRect.height - outputSize.height) < 3)
    }

    @Test
    func webContentCropDoesNotAffectDisplayCapture() {
        let rawTarget = ScreenCaptureTarget(
            selection: .display(id: 1, name: "Display"),
            contentPointSize: CGSize(width: 1_512, height: 982),
            pointPixelScale: 2
        )
        let resolved = rawTarget.applying(
            windowContentCrop: WindowContentCrop(
                topInsetPoints: 120
            )
        )

        #expect(resolved.outputCrop == nil)
        #expect(resolved.pointSize == rawTarget.pointSize)
    }

    @Test
    func webContentCropRemovesTopPixelsInMetalCompositor() throws {
        let screen = try makeBrowserTestPixelBuffer()
        let outputPool = try makeBrowserTestOutputPool()
        let compositor = try MetalVideoCompositor()

        let output = try compositor.render(
            screen: screen,
            camera: nil,
            screenCrop: NormalizedRect(
                x: 0,
                y: 0.5,
                width: 1,
                height: 0.5
            ),
            mode: .screen,
            overlay: OverlayLayout(),
            outputSize: CGSize(width: 100, height: 50),
            pool: outputPool
        )
        let pixel = readBGRA(
            from: output,
            x: 50,
            y: 5
        )

        #expect(pixel.green > pixel.red + 100)
        #expect(pixel.green > pixel.blue + 100)
    }

    @Test
    func overlayFramesStayInsideCanvasForAllSizesAndCorners() {
        let canvas = CGSize(width: 1_920, height: 1_080)
        for size in OverlaySize.allCases {
            for corner in OverlayCorner.allCases {
                let frame = OverlayLayout(corner: corner, size: size).frame(in: canvas)
                let normalized = OverlayLayout(
                    corner: corner,
                    size: size
                ).normalizedFrame(in: canvas)
                #expect(CGRect(origin: .zero, size: canvas).contains(frame))
                #expect(abs(frame.width - canvas.width * size.widthFraction) < 0.001)
                #expect(abs(frame.width / frame.height - 16.0 / 9.0) < 0.001)
                #expect(normalized.isValid)
                let roundTrip = normalized.denormalized(in: canvas)
                #expect(abs(roundTrip.minX - frame.minX) < 0.001)
                #expect(abs(roundTrip.minY - frame.minY) < 0.001)
                #expect(abs(roundTrip.width - frame.width) < 0.001)
                #expect(abs(roundTrip.height - frame.height) < 0.001)
            }
        }
    }

    @Test
    func modeDefaultsAndValidation() {
        var configuration = RecordingConfiguration(mode: .combined)
        configuration.applyDefaults(for: .screen)

        #expect(configuration.capturesSystemAudio)
        #expect(!configuration.capturesMicrophone)
        #expect(!configuration.validationIssues(hasResolvedScreenTarget: false).isEmpty)

        configuration.screenSelection = .display(id: 1, name: "Display")
        #expect(configuration.validationIssues(hasResolvedScreenTarget: true).isEmpty)

        configuration.applyDefaults(for: .camera)
        configuration.cameraDeviceID = "camera"
        configuration.microphoneDeviceID = "microphone"
        #expect(!configuration.capturesSystemAudio)
        #expect(configuration.capturesMicrophone)
        #expect(configuration.screenSelection == nil)
        #expect(configuration.validationIssues(hasResolvedScreenTarget: false).isEmpty)
    }

    @Test
    func everyModeAndAudioCombinationHasOneSharedValidationPath() {
        for mode in CaptureMode.allCases {
            for systemAudio in [false, true] {
                for microphone in [false, true] {
                    var configuration = RecordingConfiguration(
                        mode: mode,
                        screenSelection: mode.needsScreen
                            ? .display(id: 1, name: "Display")
                            : nil,
                        cameraDeviceID: mode.needsCamera ? "camera" : nil,
                        microphoneDeviceID: microphone ? "microphone" : nil,
                        capturesSystemAudio: systemAudio,
                        capturesMicrophone: microphone
                    )
                    configuration.normalizeForMode()
                    #expect(
                        configuration.validationIssues(
                            hasResolvedScreenTarget: mode.needsScreen
                        ).isEmpty
                    )
                    if !mode.needsScreen {
                        #expect(!configuration.capturesSystemAudio)
                    }
                }
            }
        }
    }

    @Test
    func timelineRemovesPausedDuration() {
        let timeline = TimelineNormalizer(epoch: CMTime(seconds: 10, preferredTimescale: 600))
        #expect(abs(timeline.normalized(CMTime(seconds: 11, preferredTimescale: 600)).seconds - 1) < 0.001)

        timeline.pause(at: CMTime(seconds: 12, preferredTimescale: 600))
        timeline.resume(at: CMTime(seconds: 15, preferredTimescale: 600))

        #expect(abs(timeline.normalized(CMTime(seconds: 16, preferredTimescale: 600)).seconds - 3) < 0.001)
    }

    @Test
    func audioMixerPrioritizesMicrophoneAndLimitsPeaks() throws {
        let mixer = PCMAudioMixer(
            includesSystemAudio: true,
            includesMicrophone: true
        )
        let system = try PCMAudioMixer.makeSampleBuffer(
            samples: [Float](repeating: 0.8, count: 2_048),
            startFrame: 0
        )
        let microphone = try PCMAudioMixer.makeSampleBuffer(
            samples: [Float](repeating: 0.6, count: 2_048),
            startFrame: 0
        )

        #expect(
            try mixer.ingest(
                AudioSample(source: .system, sampleBuffer: system),
                normalizedPTS: .zero
            ).isEmpty
        )
        let output = try mixer.ingest(
            AudioSample(source: .microphone, sampleBuffer: microphone),
            normalizedPTS: .zero
        )
        #expect(output.count == 1)
        let samples = try PCMAudioMixer.extractStereoFloatSamples(from: output[0])
        #expect(samples.allSatisfy { abs($0 - 0.891_251) < 0.000_01 })
    }

    @Test
    func audioMixerBoundsMissingSourceLeadWithSilence() throws {
        let mixer = PCMAudioMixer(
            includesSystemAudio: true,
            includesMicrophone: true
        )
        let frames = 16_000
        let system = try PCMAudioMixer.makeSampleBuffer(
            samples: [Float](repeating: 0.25, count: frames * 2),
            startFrame: 0
        )
        let output = try mixer.ingest(
            AudioSample(source: .system, sampleBuffer: system),
            normalizedPTS: .zero
        )

        #expect(!output.isEmpty)
        let samples = try PCMAudioMixer.extractStereoFloatSamples(from: output[0])
        #expect(stride(from: 1, to: samples.count, by: 2).allSatisfy {
            abs(samples[$0] - 0.125) < 0.000_01
        })
    }

    @Test
    func recordingFolderBookmarkRoundTripsAndRejectsStaleData() throws {
        let suiteName = "RecorderCoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bookmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let coder = StubBookmarkCoder()
        let store = RecordingFolderStore(
            defaults: defaults,
            bookmarkKey: "folder",
            bookmarkCoder: coder
        )
        _ = try store.save(folder)
        let resolved = try store.resolve()
        let restored = try #require(resolved)
        #expect(
            restored.url.standardizedFileURL
                == folder.standardizedFileURL
        )

        coder.isStale = true
        do {
            _ = try store.resolve()
            Issue.record("Expected a stale bookmark error")
        } catch {
            #expect(
                error as? RecordingFolderStoreError
                    == .staleBookmark
            )
        }
        #expect(defaults.data(forKey: "folder") == nil)

        _ = try store.save(folder)
        store.clear()
        #expect(defaults.data(forKey: "folder") == nil)
    }
}
}

private func makeBrowserTestPixelBuffer() throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        100,
        100,
        kCVPixelFormatType_32BGRA,
        [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw RecorderError.noVideoFrames
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw RecorderError.noVideoFrames
    }
    let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for y in 0..<100 {
        for x in 0..<100 {
            let offset = y * bytesPerRow + x * 4
            let isBrowserControls = y < 50
            bytes[offset] = 0
            bytes[offset + 1] = isBrowserControls ? 0 : 255
            bytes[offset + 2] = isBrowserControls ? 255 : 0
            bytes[offset + 3] = 255
        }
    }
    return pixelBuffer
}

private func makeBrowserTestOutputPool() throws -> CVPixelBufferPool {
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        nil,
        [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: 100,
            kCVPixelBufferHeightKey: 50,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary,
        &pool
    )
    guard status == kCVReturnSuccess, let pool else {
        throw RecorderError.noVideoFrames
    }
    return pool
}

private func readBGRA(
    from pixelBuffer: CVPixelBuffer,
    x: Int,
    y: Int
) -> (blue: Int, green: Int, red: Int) {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        return (0, 0, 0)
    }
    let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
    let offset = y * CVPixelBufferGetBytesPerRow(pixelBuffer) + x * 4
    return (
        Int(bytes[offset]),
        Int(bytes[offset + 1]),
        Int(bytes[offset + 2])
    )
}

private enum CaptureSessionLifecycleTestError: Error {
    case configurationFailed
}

private final class CaptureSessionLifecycleSpy: CaptureSessionLifecycle {
    enum Event: Equatable {
        case beginConfiguration
        case configure
        case commitConfiguration
        case start
    }

    private(set) var events = [Event]()
    private(set) var startedWhileConfiguring = false
    private var isConfiguring = false

    func beginConfiguration() {
        isConfiguring = true
        events.append(.beginConfiguration)
    }

    func recordConfiguration() {
        events.append(.configure)
    }

    func commitConfiguration() {
        isConfiguring = false
        events.append(.commitConfiguration)
    }

    func startRunning() {
        startedWhileConfiguring = isConfiguring
        events.append(.start)
    }
}

private final class StubBookmarkCoder:
    SecurityScopedBookmarkCoding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var staleStorage = false

    var isStale: Bool {
        get { lock.withLock { staleStorage } }
        set { lock.withLock { staleStorage = newValue } }
    }

    func bookmark(for url: URL) throws -> Data {
        Data(url.standardizedFileURL.path.utf8)
    }

    func resolve(
        _ bookmark: Data
    ) throws -> SecurityScopedBookmarkResolution {
        SecurityScopedBookmarkResolution(
            url: URL(
                fileURLWithPath: String(decoding: bookmark, as: UTF8.self)
            ),
            isStale: isStale
        )
    }
}
