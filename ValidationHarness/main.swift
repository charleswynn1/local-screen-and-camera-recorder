@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import RecorderCore

@main
struct RecorderCoreHarness {
    static func main() async throws {
        try validateGeometry()
        try validateConfiguration()
        try validateTimeline()
        try await validateEngine()
        try await validateMP4Writer()
        print("RecorderCoreHarness: all validations passed")
    }

    private static func validateGeometry() throws {
        let region = NormalizedRect.from(
            displayLocalAppKitRect: CGRect(x: 100, y: 50, width: 400, height: 300),
            displaySize: CGSize(width: 1_000, height: 800)
        )
        try check(abs(region.y - 0.5625) < 0.000_001, "Region Y conversion is incorrect")
        try check(region.isValid, "Region should remain inside one display")

        let cameraSize = OutputGeometry.outputSize(
            sourceSize: CGSize(width: 640, height: 480),
            preset: .standard,
            cameraOnly: true
        )
        try check(
            cameraSize == CGSize(width: 640, height: 360),
            "Camera canvas should not upscale the source"
        )

        let source = CGSize(width: 3_456, height: 2_234)
        let screenSize = OutputGeometry.outputSize(sourceSize: source, preset: .standard)
        try check(screenSize.width <= 1_920 && screenSize.height <= 1_080, "Screen output exceeds preset")
        try check(Int(screenSize.width) % 2 == 0 && Int(screenSize.height) % 2 == 0, "Output dimensions must be even")

        for size in OverlaySize.allCases {
            for corner in OverlayCorner.allCases {
                let canvas = CGSize(width: 1_920, height: 1_080)
                let frame = OverlayLayout(corner: corner, size: size).frame(in: canvas)
                try check(CGRect(origin: .zero, size: canvas).contains(frame), "Overlay escaped the canvas")
            }
        }
    }

    private static func validateConfiguration() throws {
        var configuration = RecordingConfiguration(mode: .combined)
        configuration.applyDefaults(for: .screen)
        try check(configuration.capturesSystemAudio, "Screen mode should default system audio on")
        try check(!configuration.capturesMicrophone, "Screen mode should default microphone off")
        configuration.screenSelection = .display(id: 1, name: "Display")
        try check(
            configuration.validationIssues(hasResolvedScreenTarget: true).isEmpty,
            "Valid screen configuration was rejected"
        )

        configuration.applyDefaults(for: .camera)
        configuration.cameraDeviceID = "camera"
        configuration.microphoneDeviceID = "microphone"
        try check(
            configuration.validationIssues(hasResolvedScreenTarget: false).isEmpty,
            "Valid camera configuration was rejected"
        )
    }

    private static func validateTimeline() throws {
        let timeline = TimelineNormalizer(epoch: CMTime(seconds: 10, preferredTimescale: 600))
        timeline.pause(at: CMTime(seconds: 12, preferredTimescale: 600))
        timeline.resume(at: CMTime(seconds: 15, preferredTimescale: 600))
        let normalized = timeline.normalized(CMTime(seconds: 16, preferredTimescale: 600))
        try check(abs(normalized.seconds - 3) < 0.001, "Pause duration was not removed")
    }

    private static func validateEngine() async throws {
        let output = URL(fileURLWithPath: "/tmp/harness-engine.mp4")
        let pipeline = HarnessPipeline(outputURL: output)
        let engine = RecordingEngine(factory: HarnessFactory(pipeline: pipeline))
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
        await engine.pause()
        await engine.resume()
        let result = try await engine.stop()
        try check(result == output, "Engine returned the wrong output")
        let phase = await engine.currentSnapshot().phase
        try check(phase == .completed, "Engine did not reach completed")
    }

    private static func validateMP4Writer() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalRecorderHarness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let writer = try AssetRecordingWriter(
            destinationFolder: folder,
            outputSize: CGSize(width: 640, height: 360),
            preset: .compact,
            includesAudio: false,
            now: Date(timeIntervalSince1970: 0)
        )
        try writer.start()
        guard let pool = writer.pixelBufferPool else {
            throw HarnessFailure(message: "Writer did not expose its pixel buffer pool")
        }
        for index in 0..<30 {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                pool,
                &buffer
            )
            try check(status == kCVReturnSuccess, "Could not allocate frame \(index)")
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(
                    base,
                    Int32(index * 3),
                    CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
                )
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            var accepted = false
            for _ in 0..<200 {
                if writer.appendVideo(
                    buffer,
                    at: CMTime(value: CMTimeValue(index), timescale: 30)
                ) {
                    accepted = true
                    break
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            try check(accepted, "Writer remained backpressured at frame \(index)")
        }
        let url = try await writer.finish()
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)
        try check(tracks.count == 1, "MP4 should contain exactly one video track")
        try check(duration.seconds > 0.8, "MP4 duration is unexpectedly short")
    }

    private static func check(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw HarnessFailure(message: message) }
    }
}

private struct HarnessFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct HarnessFactory: RecordingPipelineFactory {
    let pipeline: HarnessPipeline

    func makePipeline(for request: RecordingRequest) throws -> any RecordingPipeline {
        pipeline
    }
}

private final class HarnessPipeline: RecordingPipeline, @unchecked Sendable {
    let events: AsyncStream<PipelineEvent>
    private let continuation: AsyncStream<PipelineEvent>.Continuation
    private let outputURL: URL

    init(outputURL: URL) {
        self.outputURL = outputURL
        (events, continuation) = AsyncStream.makeStream()
    }

    func prepare() async throws {}
    func start() async throws {}
    func pause() async {}
    func resume() async {}

    func stop() async throws -> URL {
        continuation.finish()
        return outputURL
    }

    func cancel() async {
        continuation.finish()
    }
}
