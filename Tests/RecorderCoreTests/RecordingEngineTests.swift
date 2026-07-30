import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@testable import RecorderCore
import Testing

extension RecorderCoreTestPlan {
@Suite("Recording engine")
struct RecordingEngineTests {
    @Test
    func sourceSelectionUsesSelectingStateAndReturnsToIdle() async {
        let pipeline = FakePipeline(outputURL: URL(fileURLWithPath: "/tmp/unused.mp4"))
        let engine = RecordingEngine(factory: FakePipelineFactory(pipeline: pipeline))

        await engine.beginSelection()
        #expect(await engine.currentSnapshot().phase == .selecting)

        await engine.endSelection()
        #expect(await engine.currentSnapshot().phase == .idle)
    }

    @Test
    func stateMachineRecordsPausesResumesAndCompletes() async throws {
        let output = URL(fileURLWithPath: "/tmp/completed.mp4")
        let pipeline = FakePipeline(outputURL: output)
        let factory = FakePipelineFactory(pipeline: pipeline)
        let snapshots = SnapshotCollector()
        let engine = RecordingEngine(factory: factory) {
            snapshots.append($0)
        }
        let configuration = RecordingConfiguration(
            mode: .camera,
            cameraDeviceID: "camera",
            microphoneDeviceID: nil,
            capturesSystemAudio: false,
            capturesMicrophone: false
        )

        try await engine.start(
            RecordingRequest(
                configuration: configuration,
                screenTarget: nil,
                destinationFolder: URL(fileURLWithPath: "/tmp")
            ),
            countdown: 0
        )
        let recordingPhase = await engine.currentSnapshot().phase
        #expect(recordingPhase == .recording)

        await engine.pause()
        let pausedPhase = await engine.currentSnapshot().phase
        #expect(pausedPhase == .paused)

        await engine.resume()
        let resumedPhase = await engine.currentSnapshot().phase
        #expect(resumedPhase == .recording)

        let result = try await engine.stop()
        let completedPhase = await engine.currentSnapshot().phase
        #expect(result == output)
        #expect(completedPhase == .completed)
        #expect(pipeline.calls == [.prepare, .start, .pause, .resume, .stop])
        #expect(snapshots.values.map(\.phase).contains(.completed))
    }

    @Test
    func combinedRecordingCanToggleCameraWithoutStoppingScreen() async throws {
        let output = URL(
            fileURLWithPath: "/tmp/combined-camera-toggle.mp4"
        )
        let pipeline = FakePipeline(outputURL: output)
        let engine = RecordingEngine(
            factory: FakePipelineFactory(pipeline: pipeline)
        )
        let setup = makeSetup(
            mode: .combined,
            screenKind: .display,
            systemAudio: true,
            microphone: true
        )

        try await engine.start(
            RecordingRequest(
                configuration: setup.configuration,
                screenTarget: setup.target,
                destinationFolder: URL(fileURLWithPath: "/tmp")
            ),
            countdown: 0
        )
        #expect(await engine.currentSnapshot().isCameraEnabled)

        try await engine.setCameraEnabled(false)
        #expect(await engine.currentSnapshot().phase == .recording)
        #expect(await !engine.currentSnapshot().isCameraEnabled)

        try await engine.setCameraEnabled(true)
        #expect(await engine.currentSnapshot().phase == .recording)
        #expect(await engine.currentSnapshot().isCameraEnabled)

        #expect(try await engine.stop() == output)
        #expect(
            pipeline.calls == [
                .prepare,
                .start,
                .setCameraEnabled(false),
                .setCameraEnabled(true),
                .stop
            ]
        )
    }

    @Test
    func recordingPreviewFramesAreForwardedWhileRecording() async throws {
        let output = URL(fileURLWithPath: "/tmp/preview.mp4")
        let pipeline = FakePipeline(outputURL: output)
        let previews = PreviewFrameCollector()
        let engine = RecordingEngine(
            factory: FakePipelineFactory(pipeline: pipeline),
            updateHandler: { _ in },
            previewHandler: { frame in
                previews.append(frame)
            }
        )
        let configuration = RecordingConfiguration(
            mode: .camera,
            cameraDeviceID: "camera",
            capturesSystemAudio: false,
            capturesMicrophone: false
        )

        try await engine.start(
            RecordingRequest(
                configuration: configuration,
                screenTarget: nil,
                destinationFolder: URL(fileURLWithPath: "/tmp")
            ),
            countdown: 0
        )
        let pixelBuffer = try makeTestPixelBuffer(
            width: 640,
            height: 360
        )
        pipeline.sendPreview(
            RecordingPreviewFrame(
                pixelBuffer: pixelBuffer,
                presentationTime: CMTime(value: 1, timescale: 10)
            )
        )

        let frameArrived = await waitUntil {
            previews.values == [
                PreviewFrameCollector.Value(
                    width: 640,
                    height: 360,
                    presentationTime: CMTime(value: 1, timescale: 10)
                )
            ]
        }
        #expect(frameArrived)
        #expect(try await engine.stop() == output)
    }

    @Test
    func prepareFailureTransitionsToFailedAndCancels() async {
        let pipeline = FakePipeline(
            outputURL: URL(fileURLWithPath: "/tmp/unused.mp4"),
            prepareError: RecorderError.destinationUnavailable
        )
        let engine = RecordingEngine(factory: FakePipelineFactory(pipeline: pipeline))
        let configuration = RecordingConfiguration(
            mode: .camera,
            cameraDeviceID: "camera",
            capturesSystemAudio: false,
            capturesMicrophone: false
        )

        do {
            try await engine.start(
                RecordingRequest(
                    configuration: configuration,
                    screenTarget: nil,
                    destinationFolder: URL(fileURLWithPath: "/tmp")
                ),
                countdown: 0
            )
            Issue.record("Expected start to fail")
        } catch {
            #expect(error as? RecorderError == .destinationUnavailable)
        }

        let failedPhase = await engine.currentSnapshot().phase
        #expect(failedPhase == .failed)
        #expect(pipeline.calls == [.prepare, .cancel])
    }

    @Test
    func pipelineStopEventFinalizesRecording() async throws {
        let output = URL(fileURLWithPath: "/tmp/event-stop.mp4")
        let pipeline = FakePipeline(outputURL: output)
        let engine = RecordingEngine(factory: FakePipelineFactory(pipeline: pipeline))
        let configuration = RecordingConfiguration(
            mode: .camera,
            cameraDeviceID: "camera",
            capturesSystemAudio: false,
            capturesMicrophone: false
        )

        try await engine.start(
            RecordingRequest(
                configuration: configuration,
                screenTarget: nil,
                destinationFolder: URL(fileURLWithPath: "/tmp")
            ),
            countdown: 0
        )
        pipeline.send(.stopRequested("Camera disconnected."))

        let completed = await waitUntil {
            await engine.currentSnapshot().phase == .completed
        }
        let completedURL = await engine.currentSnapshot().outputURL
        #expect(completed)
        #expect(completedURL == output)
    }

    @Test
    func everyModeScreenSourceAndAudioCombinationUsesTheSameEngine() async throws {
        for mode in CaptureMode.allCases {
            let sourceKinds: [ScreenSelectionKind?] = mode.needsScreen
                ? ScreenSelectionKind.allCases.map(Optional.some)
                : [nil]
            for sourceKind in sourceKinds {
                for systemAudio in [false, true] {
                    for microphone in [false, true] {
                        let output = URL(
                            fileURLWithPath: "/tmp/\(UUID().uuidString).mp4"
                        )
                        let pipeline = FakePipeline(outputURL: output)
                        let engine = RecordingEngine(
                            factory: FakePipelineFactory(pipeline: pipeline)
                        )
                        let setup = makeSetup(
                            mode: mode,
                            screenKind: sourceKind,
                            systemAudio: systemAudio,
                            microphone: microphone
                        )

                        try await engine.start(
                            RecordingRequest(
                                configuration: setup.configuration,
                                screenTarget: setup.target,
                                destinationFolder: URL(fileURLWithPath: "/tmp")
                            ),
                            countdown: 0
                        )
                        #expect(await engine.currentSnapshot().phase == .recording)
                        #expect(try await engine.stop() == output)
                        #expect(
                            pipeline.calls == [.prepare, .start, .stop]
                        )
                    }
                }
            }
        }
    }

    @Test
    func countdownCancellationReturnsToIdleAndCancelsPreparedPipeline() async {
        let pipeline = FakePipeline(
            outputURL: URL(fileURLWithPath: "/tmp/countdown.mp4")
        )
        let engine = RecordingEngine(
            factory: FakePipelineFactory(pipeline: pipeline)
        )
        let setup = makeSetup(
            mode: .camera,
            screenKind: nil,
            systemAudio: false,
            microphone: false
        )

        let startTask = Task {
            try await engine.start(
                RecordingRequest(
                    configuration: setup.configuration,
                    screenTarget: nil,
                    destinationFolder: URL(fileURLWithPath: "/tmp")
                ),
                countdown: 30
            )
        }
        let enteredCountdown = await waitUntil {
            await engine.currentSnapshot().phase == .countingDown
        }
        #expect(enteredCountdown)
        await engine.cancelCountdown()
        _ = try? await startTask.value

        #expect(await engine.currentSnapshot().phase == .idle)
        #expect(pipeline.calls == [.prepare, .cancel])
    }

    @Test
    func permissionDenialFailsBeforeCaptureStarts() async {
        let pipeline = FakePipeline(
            outputURL: URL(fileURLWithPath: "/tmp/permission.mp4"),
            prepareError: RecorderError.permissionDenied(.camera)
        )
        let engine = RecordingEngine(
            factory: FakePipelineFactory(pipeline: pipeline)
        )
        let setup = makeSetup(
            mode: .camera,
            screenKind: nil,
            systemAudio: false,
            microphone: false
        )

        do {
            try await engine.start(
                RecordingRequest(
                    configuration: setup.configuration,
                    screenTarget: nil,
                    destinationFolder: URL(fileURLWithPath: "/tmp")
                ),
                countdown: 0
            )
            Issue.record("Expected permission denial")
        } catch {
            #expect(
                error as? RecorderError
                    == RecorderError.permissionDenied(.camera)
            )
        }
        #expect(await engine.currentSnapshot().phase == .failed)
        #expect(pipeline.calls == [.prepare, .cancel])
    }

    @Test
    func fatalWriterEventCancelsAndFailsWithoutPublishingOutput() async throws {
        let pipeline = FakePipeline(
            outputURL: URL(fileURLWithPath: "/tmp/writer-failure.mp4")
        )
        let engine = RecordingEngine(
            factory: FakePipelineFactory(pipeline: pipeline)
        )
        let setup = makeSetup(
            mode: .camera,
            screenKind: nil,
            systemAudio: false,
            microphone: false
        )
        try await engine.start(
            RecordingRequest(
                configuration: setup.configuration,
                screenTarget: nil,
                destinationFolder: URL(fileURLWithPath: "/tmp")
            ),
            countdown: 0
        )

        pipeline.send(.fatal("The writer failed."))
        let failed = await waitUntil {
            await engine.currentSnapshot().phase == .failed
        }
        #expect(failed)
        #expect(await engine.currentSnapshot().outputURL == nil)
        #expect(pipeline.calls == [.prepare, .start, .cancel])
    }

    @Test
    func audioLossWarningKeepsVideoRecording() async throws {
        let pipeline = FakePipeline(
            outputURL: URL(fileURLWithPath: "/tmp/audio-loss.mp4")
        )
        let engine = RecordingEngine(
            factory: FakePipelineFactory(pipeline: pipeline)
        )
        let setup = makeSetup(
            mode: .combined,
            screenKind: .display,
            systemAudio: true,
            microphone: true
        )
        try await engine.start(
            RecordingRequest(
                configuration: setup.configuration,
                screenTarget: setup.target,
                destinationFolder: URL(fileURLWithPath: "/tmp")
            ),
            countdown: 0
        )

        pipeline.send(.warning("Microphone disconnected."))
        let warningApplied = await waitUntil {
            let snapshot = await engine.currentSnapshot()
            return snapshot.phase == .recording
                && snapshot.message == "Microphone disconnected."
        }
        #expect(warningApplied)
        _ = try await engine.stop()
        #expect(await engine.currentSnapshot().phase == .completed)
    }

    @Test
    func lowDiskAndScreenLossEventsGracefullyFinalize() async throws {
        for message in [
            "Disk space is critically low.",
            "Selected window disappeared.",
            "Selected display disconnected."
        ] {
            let output = URL(
                fileURLWithPath: "/tmp/\(UUID().uuidString).mp4"
            )
            let pipeline = FakePipeline(outputURL: output)
            let engine = RecordingEngine(
                factory: FakePipelineFactory(pipeline: pipeline)
            )
            let setup = makeSetup(
                mode: .screen,
                screenKind: .window,
                systemAudio: true,
                microphone: false
            )
            try await engine.start(
                RecordingRequest(
                    configuration: setup.configuration,
                    screenTarget: setup.target,
                    destinationFolder: URL(fileURLWithPath: "/tmp")
                ),
                countdown: 0
            )

            pipeline.send(.stopRequested(message))
            let completed = await waitUntil {
                await engine.currentSnapshot().phase == .completed
            }
            #expect(completed)
            let snapshot = await engine.currentSnapshot()
            #expect(snapshot.outputURL == output)
            #expect(snapshot.message == message)
        }
    }

    @Test
    func writerFailureDuringFinalizationTransitionsToFailed() async throws {
        let pipeline = FakePipeline(
            outputURL: URL(fileURLWithPath: "/tmp/unused.mp4"),
            stopError: RecorderError.writerFailed("Disk write failed.")
        )
        let engine = RecordingEngine(
            factory: FakePipelineFactory(pipeline: pipeline)
        )
        let setup = makeSetup(
            mode: .camera,
            screenKind: nil,
            systemAudio: false,
            microphone: false
        )
        try await engine.start(
            RecordingRequest(
                configuration: setup.configuration,
                screenTarget: nil,
                destinationFolder: URL(fileURLWithPath: "/tmp")
            ),
            countdown: 0
        )

        do {
            _ = try await engine.stop()
            Issue.record("Expected finalization to fail")
        } catch {
            #expect(
                error as? RecorderError
                    == RecorderError.writerFailed("Disk write failed.")
            )
        }
        #expect(await engine.currentSnapshot().phase == .failed)
        #expect(
            pipeline.calls == [.prepare, .start, .stop, .cancel]
        )
    }

    private func makeSetup(
        mode: CaptureMode,
        screenKind: ScreenSelectionKind?,
        systemAudio: Bool,
        microphone: Bool
    ) -> (
        configuration: RecordingConfiguration,
        target: ScreenCaptureTarget?
    ) {
        let selection: ScreenSelection?
        switch screenKind {
        case .display:
            selection = .display(id: 1, name: "Display")
        case .window:
            selection = .window(id: 2, title: "Window")
        case .region:
            selection = .region(
                displayID: 1,
                displayName: "Display",
                rect: NormalizedRect(
                    x: 0.1,
                    y: 0.1,
                    width: 0.8,
                    height: 0.8
                )
            )
        case nil:
            selection = nil
        }
        let target = selection.map {
            ScreenCaptureTarget(
                selection: $0,
                contentPointSize: CGSize(width: 1_440, height: 900),
                pointPixelScale: 2
            )
        }
        return (
            RecordingConfiguration(
                mode: mode,
                screenSelection: selection,
                cameraDeviceID: mode.needsCamera ? "camera" : nil,
                microphoneDeviceID: microphone ? "microphone" : nil,
                capturesSystemAudio: systemAudio,
                capturesMicrophone: microphone
            ),
            target
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
}

extension RecorderCoreTestPlan {
@Suite("Live pipeline source failure policy")
struct LivePipelineFailurePolicyTests {
    @Test
    func everyModeSourceAndAudioCombinationStartsExpectedSources() async throws {
        for mode in CaptureMode.allCases {
            let screenKinds: [ScreenSelectionKind?] = mode.needsScreen
                ? ScreenSelectionKind.allCases.map(Optional.some)
                : [nil]
            for screenKind in screenKinds {
                for systemAudio in [false, true] {
                    for microphone in [false, true] {
                        let setup = try makePipeline(
                            mode: mode,
                            screenKind: screenKind,
                            systemAudio: systemAudio,
                            microphone: microphone
                        )
                        try await setup.pipeline.prepare()
                        try await setup.pipeline.start()

                        #expect(
                            setup.screen.startCount
                                == (mode.needsScreen ? 1 : 0)
                        )
                        #expect(
                            setup.camera.startCount
                                == (mode.needsCamera ? 1 : 0)
                        )
                        #expect(
                            setup.microphone.startCount
                                == (microphone ? 1 : 0)
                        )
                        if mode.needsScreen {
                            #expect(
                                setup.screen.lastConfiguration?
                                    .capturesSystemAudio
                                    == systemAudio
                            )
                        }
                        _ = try await setup.pipeline.stop()
                    }
                }
            }
        }
    }

    @Test
    func combinedCameraLossRemovesOverlayAndContinuesScreenCapture() async throws {
        let setup = try makePipeline(mode: .combined)
        try await setup.pipeline.prepare()
        try await setup.pipeline.start()
        let nextEvent = Task {
            var iterator = setup.pipeline.events.makeAsyncIterator()
            return await iterator.next()
        }

        setup.camera.send(.stopRequested("Camera disconnected."))
        guard let event = await nextEvent.value,
              case let .cameraDisabled(message) = event else {
            Issue.record("Combined camera loss should disable only the camera")
            return
        }
        #expect(message.contains("continuing"))
        #expect(setup.screen.isRunning)
        #expect(try await setup.pipeline.stop() == setup.outputURL)
    }

    @Test
    func combinedCameraCanStopAndRestartWhileScreenContinues() async throws {
        let compositor = CameraPresenceVideoCompositor()
        let setup = try makePipeline(
            mode: .combined,
            compositor: compositor
        )
        try await setup.pipeline.prepare()
        try await setup.pipeline.start()

        #expect(setup.screen.isRunning)
        #expect(setup.camera.isRunning)
        #expect(setup.camera.startCount == 1)

        var presentationTime = CMClockGetTime(
            CMClockGetHostTimeClock()
        )
        setup.camera.send(
            try makeTestVideoSample(
                width: 320,
                height: 180,
                presentationTime: presentationTime
            )
        )
        setup.screen.send(
            try makeTestVideoSample(
                width: 640,
                height: 360,
                presentationTime: presentationTime
            )
        )
        #expect(
            await waitForPreview {
                compositor.cameraPresence.last == true
            }
        )

        try await setup.pipeline.setCameraEnabled(false)
        #expect(setup.screen.isRunning)
        #expect(!setup.camera.isRunning)
        #expect(setup.camera.stopCount == 1)
        presentationTime = CMTimeAdd(
            presentationTime,
            CMTime(value: 1, timescale: 30)
        )
        setup.screen.send(
            try makeTestVideoSample(
                width: 640,
                height: 360,
                presentationTime: presentationTime
            )
        )
        #expect(
            await waitForPreview {
                compositor.cameraPresence.last == false
            }
        )

        try await setup.pipeline.setCameraEnabled(true)
        #expect(setup.screen.isRunning)
        #expect(setup.camera.isRunning)
        #expect(setup.camera.startCount == 2)
        presentationTime = CMTimeAdd(
            presentationTime,
            CMTime(value: 1, timescale: 30)
        )
        setup.camera.send(
            try makeTestVideoSample(
                width: 320,
                height: 180,
                presentationTime: presentationTime
            )
        )
        setup.screen.send(
            try makeTestVideoSample(
                width: 640,
                height: 360,
                presentationTime: presentationTime
            )
        )
        #expect(
            await waitForPreview {
                compositor.cameraPresence.last == true
            }
        )

        #expect(try await setup.pipeline.stop() == setup.outputURL)
        #expect(setup.screen.startCount == 1)
    }

    @Test
    func cameraOnlyLossRequestsGracefulStop() async throws {
        let setup = try makePipeline(mode: .camera)
        try await setup.pipeline.prepare()
        try await setup.pipeline.start()
        let nextEvent = Task {
            var iterator = setup.pipeline.events.makeAsyncIterator()
            return await iterator.next()
        }

        setup.camera.send(.stopRequested("Camera disconnected."))
        let event = await nextEvent.value
        #expect(event == .stopRequested("Camera disconnected."))
        #expect(try await setup.pipeline.stop() == setup.outputURL)
    }

    @Test
    func cameraOnlyPublishesTheCompositedRecordingFrameForPreview() async throws {
        let camera = EventCameraSource()
        let outputURL = URL(
            fileURLWithPath: "/tmp/\(UUID().uuidString).mp4"
        )
        let pipeline = try LiveRecordingPipeline(
            request: RecordingRequest(
                configuration: RecordingConfiguration(
                    mode: .camera,
                    cameraDeviceID: "camera",
                    capturesSystemAudio: false,
                    capturesMicrophone: false
                ),
                screenTarget: nil,
                destinationFolder: FileManager.default.temporaryDirectory
            ),
            outputSize: CGSize(width: 640, height: 360),
            screenSource: EventScreenSource(),
            cameraSource: camera,
            microphoneSource: EventMicrophoneSource(),
            compositor: SolidVideoCompositor(),
            audioMixer: NoopAudioMixer(),
            writer: EventRecordingWriter(outputURL: outputURL),
            diskSpaceChecker: MutableDiskSpaceChecker(
                capacity: 2_000_000_000
            )
        )
        let previews = PreviewFrameCollector()
        let observer = Task {
            for await frame in pipeline.previewFrames {
                previews.append(frame)
                return
            }
        }

        try await pipeline.prepare()
        try await pipeline.start()
        camera.send(
            try makeTestVideoSample(
                width: 320,
                height: 180,
                presentationTime: CMClockGetTime(
                    CMClockGetHostTimeClock()
                )
            )
        )

        let previewArrived = await waitForPreview {
            previews.values.first.map {
                $0.width == 640 && $0.height == 360
            } == true
        }
        #expect(previewArrived)
        observer.cancel()
        #expect(try await pipeline.stop() == outputURL)
    }

    @Test
    func audioWarningsContinueButScreenLossRequestsStop() async throws {
        let setup = try makePipeline(mode: .combined)
        try await setup.pipeline.prepare()
        try await setup.pipeline.start()
        var iterator = setup.pipeline.events.makeAsyncIterator()

        setup.microphone.send(.warning("Microphone disconnected."))
        #expect(
            await iterator.next()
                == .warning("Microphone disconnected.")
        )

        setup.screen.send(.stopRequested("Selected display disappeared."))
        #expect(
            await iterator.next()
                == .stopRequested("Selected display disappeared.")
        )
        #expect(try await setup.pipeline.stop() == setup.outputURL)
    }

    @Test
    func criticallyLowDiskRequestsGracefulStop() async throws {
        let setup = try makePipeline(mode: .combined)
        try await setup.pipeline.prepare()
        try await setup.pipeline.start()
        var iterator = setup.pipeline.events.makeAsyncIterator()

        setup.diskSpaceChecker.capacity = 100_000_000
        #expect(
            await iterator.next()
                == .stopRequested(
                    "Disk space is critically low. The recording is being finalized."
                )
        )
        #expect(try await setup.pipeline.stop() == setup.outputURL)
    }

    @Test
    func insufficientStartingDiskSpaceIsRejected() async throws {
        let checker = MutableDiskSpaceChecker(capacity: 100_000_000)
        let setup = try makePipeline(
            mode: .combined,
            diskSpaceChecker: checker
        )
        await #expect(throws: RecorderError.self) {
            try await setup.pipeline.prepare()
        }
    }

    private func makePipeline(
        mode: CaptureMode,
        screenKind: ScreenSelectionKind? = .display,
        systemAudio: Bool? = nil,
        microphone: Bool = true,
        compositor: any VideoCompositor = NoopVideoCompositor(),
        diskSpaceChecker: MutableDiskSpaceChecker =
            MutableDiskSpaceChecker(capacity: 2_000_000_000)
    ) throws -> (
        pipeline: LiveRecordingPipeline,
        screen: EventScreenSource,
        camera: EventCameraSource,
        microphone: EventMicrophoneSource,
        diskSpaceChecker: MutableDiskSpaceChecker,
        outputURL: URL
    ) {
        let screen = EventScreenSource()
        let camera = EventCameraSource()
        let microphoneSource = EventMicrophoneSource()
        let outputURL = URL(
            fileURLWithPath: "/tmp/\(UUID().uuidString).mp4"
        )
        let selection: ScreenSelection?
        switch mode.needsScreen ? screenKind : nil {
        case .display:
            selection = .display(id: 1, name: "Display")
        case .window:
            selection = .window(id: 2, title: "Window")
        case .region:
            selection = .region(
                displayID: 1,
                displayName: "Display",
                rect: NormalizedRect(
                    x: 0.1,
                    y: 0.1,
                    width: 0.8,
                    height: 0.8
                )
            )
        case nil:
            selection = nil
        }
        let target = selection.map {
            ScreenCaptureTarget(
                selection: $0,
                contentPointSize: CGSize(width: 1_440, height: 900),
                pointPixelScale: 2
            )
        }
        let configuration = RecordingConfiguration(
            mode: mode,
            screenSelection: selection,
            cameraDeviceID: mode.needsCamera ? "camera" : nil,
            microphoneDeviceID: microphone ? "microphone" : nil,
            capturesSystemAudio: systemAudio ?? mode.needsScreen,
            capturesMicrophone: microphone
        )
        let pipeline = try LiveRecordingPipeline(
            request: RecordingRequest(
                configuration: configuration,
                screenTarget: target,
                destinationFolder: FileManager.default.temporaryDirectory
            ),
            outputSize: CGSize(width: 640, height: 360),
            screenSource: screen,
            cameraSource: camera,
            microphoneSource: microphoneSource,
            compositor: compositor,
            audioMixer: NoopAudioMixer(),
            writer: EventRecordingWriter(outputURL: outputURL),
            diskSpaceChecker: diskSpaceChecker,
            diskMonitorInterval: .milliseconds(10)
        )
        return (
            pipeline,
            screen,
            camera,
            microphoneSource,
            diskSpaceChecker,
            outputURL
        )
    }

    private func waitForPreview(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
}

private final class SnapshotCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [RecordingSnapshot]()

    var values: [RecordingSnapshot] {
        lock.withLock { storage }
    }

    func append(_ snapshot: RecordingSnapshot) {
        lock.withLock { storage.append(snapshot) }
    }
}

private final class PreviewFrameCollector: @unchecked Sendable {
    struct Value: Equatable {
        let width: Int
        let height: Int
        let presentationTime: CMTime
    }

    private let lock = NSLock()
    private var storage = [Value]()

    var values: [Value] {
        lock.withLock { storage }
    }

    func append(_ frame: RecordingPreviewFrame) {
        lock.withLock {
            storage.append(
                Value(
                    width: CVPixelBufferGetWidth(frame.pixelBuffer),
                    height: CVPixelBufferGetHeight(frame.pixelBuffer),
                    presentationTime: frame.presentationTime
                )
            )
        }
    }
}

private final class EventScreenSource: ScreenSource, @unchecked Sendable {
    private let lock = NSLock()
    private var videoHandler: (@Sendable (VideoSample) -> Void)?
    private var eventHandler: (@Sendable (PipelineEvent) -> Void)?
    private var isRunningStorage = false
    private var startCountStorage = 0
    private var configurationStorage: ScreenSourceConfiguration?

    var isRunning: Bool {
        lock.withLock { isRunningStorage }
    }

    var startCount: Int {
        lock.withLock { startCountStorage }
    }

    var lastConfiguration: ScreenSourceConfiguration? {
        lock.withLock { configurationStorage }
    }

    func start(
        target: ScreenCaptureTarget,
        configuration: ScreenSourceConfiguration,
        videoHandler: @escaping @Sendable (VideoSample) -> Void,
        audioHandler: @escaping @Sendable (AudioSample) -> Void,
        eventHandler: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        lock.withLock {
            self.videoHandler = videoHandler
            self.eventHandler = eventHandler
            isRunningStorage = true
            startCountStorage += 1
            configurationStorage = configuration
        }
    }

    func stop() async {
        lock.withLock {
            isRunningStorage = false
            videoHandler = nil
            eventHandler = nil
        }
    }

    func send(_ event: PipelineEvent) {
        let handler = lock.withLock { eventHandler }
        handler?(event)
    }

    func send(_ sample: VideoSample) {
        let handler = lock.withLock { videoHandler }
        handler?(sample)
    }
}

private final class EventCameraSource: CameraSource, @unchecked Sendable {
    private let lock = NSLock()
    private var videoHandler: (@Sendable (VideoSample) -> Void)?
    private var eventHandler: (@Sendable (PipelineEvent) -> Void)?
    private var startCountStorage = 0
    private var stopCountStorage = 0
    private var isRunningStorage = false

    var startCount: Int {
        lock.withLock { startCountStorage }
    }

    var stopCount: Int {
        lock.withLock { stopCountStorage }
    }

    var isRunning: Bool {
        lock.withLock { isRunningStorage }
    }

    func start(
        cameraDeviceID: String?,
        maximumVideoSize: CGSize,
        framesPerSecond: Int32,
        videoHandler: @escaping @Sendable (VideoSample) -> Void,
        eventHandler: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        lock.withLock {
            self.videoHandler = videoHandler
            self.eventHandler = eventHandler
            startCountStorage += 1
            isRunningStorage = true
        }
    }

    func stop() async {
        lock.withLock {
            videoHandler = nil
            eventHandler = nil
            stopCountStorage += 1
            isRunningStorage = false
        }
    }

    func send(_ event: PipelineEvent) {
        let handler = lock.withLock { eventHandler }
        handler?(event)
    }

    func send(_ sample: VideoSample) {
        let handler = lock.withLock { videoHandler }
        handler?(sample)
    }
}

private final class EventMicrophoneSource:
    MicrophoneSource,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var eventHandler: (@Sendable (PipelineEvent) -> Void)?
    private var startCountStorage = 0

    var startCount: Int {
        lock.withLock { startCountStorage }
    }

    func start(
        microphoneDeviceID: String?,
        audioHandler: @escaping @Sendable (AudioSample) -> Void,
        eventHandler: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        lock.withLock {
            self.eventHandler = eventHandler
            startCountStorage += 1
        }
    }

    func stop() async {
        lock.withLock {
            eventHandler = nil
        }
    }

    func send(_ event: PipelineEvent) {
        let handler = lock.withLock { eventHandler }
        handler?(event)
    }
}

private final class NoopAudioMixer: AudioMixer, @unchecked Sendable {
    func ingest(
        _ sample: AudioSample,
        normalizedPTS: CMTime
    ) throws -> [CMSampleBuffer] {
        []
    }

    func finish() throws -> [CMSampleBuffer] {
        []
    }
}

private final class NoopVideoCompositor: VideoCompositor, @unchecked Sendable {
    func render(
        screen: CVPixelBuffer?,
        camera: CVPixelBuffer?,
        screenCrop: NormalizedRect?,
        mode: CaptureMode,
        overlay: OverlayLayout,
        outputSize: CGSize,
        pool: CVPixelBufferPool
    ) throws -> CVPixelBuffer {
        throw RecorderError.noVideoFrames
    }
}

private final class SolidVideoCompositor:
    VideoCompositor,
    @unchecked Sendable
{
    func render(
        screen: CVPixelBuffer?,
        camera: CVPixelBuffer?,
        screenCrop: NormalizedRect?,
        mode: CaptureMode,
        overlay: OverlayLayout,
        outputSize: CGSize,
        pool: CVPixelBufferPool
    ) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &output
        )
        guard status == kCVReturnSuccess, let output else {
            throw RecorderError.noVideoFrames
        }
        return output
    }
}

private final class CameraPresenceVideoCompositor:
    VideoCompositor,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var cameraPresenceStorage = [Bool]()

    var cameraPresence: [Bool] {
        lock.withLock { cameraPresenceStorage }
    }

    func render(
        screen: CVPixelBuffer?,
        camera: CVPixelBuffer?,
        screenCrop: NormalizedRect?,
        mode: CaptureMode,
        overlay: OverlayLayout,
        outputSize: CGSize,
        pool: CVPixelBufferPool
    ) throws -> CVPixelBuffer {
        lock.withLock {
            cameraPresenceStorage.append(camera != nil)
        }
        var output: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &output
        )
        guard status == kCVReturnSuccess, let output else {
            throw RecorderError.noVideoFrames
        }
        return output
    }
}

private final class EventRecordingWriter: RecordingWriter, @unchecked Sendable {
    let outputURL: URL
    let pixelBufferPool: CVPixelBufferPool?

    init(outputURL: URL) {
        self.outputURL = outputURL
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            [
                kCVPixelBufferPixelFormatTypeKey:
                    kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: 640,
                kCVPixelBufferHeightKey: 360,
                kCVPixelBufferMetalCompatibilityKey: true
            ] as CFDictionary,
            &pool
        )
        pixelBufferPool = pool
    }

    func start() throws {}

    func appendVideo(
        _ pixelBuffer: CVPixelBuffer,
        at presentationTime: CMTime
    ) -> Bool {
        true
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) -> Bool {
        true
    }

    func finish() async throws -> URL {
        outputURL
    }

    func cancel() {}
}

private final class MutableDiskSpaceChecker:
    DiskSpaceChecking,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var capacityStorage: Int64?

    var capacity: Int64? {
        get { lock.withLock { capacityStorage } }
        set { lock.withLock { capacityStorage = newValue } }
    }

    init(capacity: Int64?) {
        capacityStorage = capacity
    }

    func availableCapacity(at folder: URL) -> Int64? {
        capacity
    }
}

private struct FakePipelineFactory: RecordingPipelineFactory {
    let pipeline: FakePipeline

    func makePipeline(for request: RecordingRequest) throws -> any RecordingPipeline {
        pipeline
    }
}

private final class FakePipeline: RecordingPipeline, @unchecked Sendable {
    enum Call: Equatable {
        case prepare
        case start
        case pause
        case resume
        case setCameraEnabled(Bool)
        case stop
        case cancel
    }

    let events: AsyncStream<PipelineEvent>
    let previewFrames: AsyncStream<RecordingPreviewFrame>
    private let continuation: AsyncStream<PipelineEvent>.Continuation
    private let previewContinuation:
        AsyncStream<RecordingPreviewFrame>.Continuation
    private let outputURL: URL
    private let prepareError: Error?
    private let stopError: Error?
    private let lock = NSLock()
    private var callStorage = [Call]()

    var calls: [Call] {
        lock.withLock { callStorage }
    }

    init(
        outputURL: URL,
        prepareError: Error? = nil,
        stopError: Error? = nil
    ) {
        self.outputURL = outputURL
        self.prepareError = prepareError
        self.stopError = stopError
        (events, continuation) = AsyncStream.makeStream()
        (previewFrames, previewContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    func prepare() async throws {
        append(.prepare)
        if let prepareError { throw prepareError }
    }

    func start() async throws {
        append(.start)
    }

    func pause() async {
        append(.pause)
    }

    func resume() async {
        append(.resume)
    }

    func setCameraEnabled(_ enabled: Bool) async throws {
        append(.setCameraEnabled(enabled))
    }

    func stop() async throws -> URL {
        append(.stop)
        if let stopError {
            throw stopError
        }
        continuation.finish()
        previewContinuation.finish()
        return outputURL
    }

    func cancel() async {
        append(.cancel)
        continuation.finish()
        previewContinuation.finish()
    }

    func send(_ event: PipelineEvent) {
        continuation.yield(event)
    }

    func sendPreview(_ frame: RecordingPreviewFrame) {
        previewContinuation.yield(frame)
    }

    private func append(_ call: Call) {
        lock.withLock { callStorage.append(call) }
    }
}

private func makeTestPixelBuffer(
    width: Int,
    height: Int
) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw RecorderError.noVideoFrames
    }
    return pixelBuffer
}

private func makeTestVideoSample(
    width: Int,
    height: Int,
    presentationTime: CMTime
) throws -> VideoSample {
    let pixelBuffer = try makeTestPixelBuffer(
        width: width,
        height: height
    )
    var formatDescription: CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr, let formatDescription else {
        throw RecorderError.noVideoFrames
    }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: presentationTime,
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: formatDescription,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer else {
        throw RecorderError.noVideoFrames
    }
    return VideoSample(sampleBuffer)
}
