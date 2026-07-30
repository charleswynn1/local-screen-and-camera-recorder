import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

public protocol ScreenSource: AnyObject, Sendable {
    func start(
        target: ScreenCaptureTarget,
        configuration: ScreenSourceConfiguration,
        videoHandler: @escaping @Sendable (VideoSample) -> Void,
        audioHandler: @escaping @Sendable (AudioSample) -> Void,
        eventHandler: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws
    func stop() async
}

public protocol CameraSource: AnyObject, Sendable {
    func start(
        cameraDeviceID: String?,
        maximumVideoSize: CGSize,
        framesPerSecond: Int32,
        videoHandler: @escaping @Sendable (VideoSample) -> Void,
        eventHandler: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws
    func stop() async
}

public protocol MicrophoneSource: AnyObject, Sendable {
    func start(
        microphoneDeviceID: String?,
        audioHandler: @escaping @Sendable (AudioSample) -> Void,
        eventHandler: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws
    func stop() async
}

public protocol AudioMixer: AnyObject, Sendable {
    func ingest(_ sample: AudioSample, normalizedPTS: CMTime) throws -> [CMSampleBuffer]
    func finish() throws -> [CMSampleBuffer]
}

public protocol VideoCompositor: AnyObject, Sendable {
    func render(
        screen: CVPixelBuffer?,
        camera: CVPixelBuffer?,
        screenCrop: NormalizedRect?,
        mode: CaptureMode,
        overlay: OverlayLayout,
        outputSize: CGSize,
        pool: CVPixelBufferPool
    ) throws -> CVPixelBuffer
}

public protocol RecordingWriter: AnyObject, Sendable {
    var pixelBufferPool: CVPixelBufferPool? { get }
    var failure: RecorderError? { get }
    func start() throws
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at presentationTime: CMTime) -> Bool
    func appendAudio(_ sampleBuffer: CMSampleBuffer) -> Bool
    func finish() async throws -> URL
    func cancel()
}

public extension RecordingWriter {
    var failure: RecorderError? { nil }
}

public protocol RecordingLibrary: Sendable {
    func recordings(in folder: URL) async throws -> [RecordingArtifact]
    func rename(_ artifact: RecordingArtifact, to requestedName: String) async throws -> RecordingArtifact
    func moveToTrash(_ artifact: RecordingArtifact) async throws
}

public protocol DiskSpaceChecking: Sendable {
    func availableCapacity(at folder: URL) -> Int64?
}

public protocol RecordingPipeline: AnyObject, Sendable {
    var events: AsyncStream<PipelineEvent> { get }
    var previewFrames: AsyncStream<RecordingPreviewFrame> { get }
    func prepare() async throws
    func start() async throws
    func pause() async
    func resume() async
    func setCameraEnabled(_ enabled: Bool) async throws
    func stop() async throws -> URL
    func cancel() async
}

public extension RecordingPipeline {
    var previewFrames: AsyncStream<RecordingPreviewFrame> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

public protocol RecordingPipelineFactory: Sendable {
    func makePipeline(for request: RecordingRequest) throws -> any RecordingPipeline
}

public struct ScreenSourceConfiguration: Sendable {
    public let outputSize: CGSize
    public let framesPerSecond: Int32
    public let capturesSystemAudio: Bool
    public let showsCursor: Bool
    public let showsMouseClicks: Bool

    public init(
        outputSize: CGSize,
        framesPerSecond: Int32,
        capturesSystemAudio: Bool,
        showsCursor: Bool,
        showsMouseClicks: Bool
    ) {
        self.outputSize = outputSize
        self.framesPerSecond = framesPerSecond
        self.capturesSystemAudio = capturesSystemAudio
        self.showsCursor = showsCursor
        self.showsMouseClicks = showsMouseClicks
    }
}

public enum RecorderError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case permissionDenied(PermissionKind)
    case captureFailed(String)
    case writerFailed(String)
    case noPixelBufferPool
    case noVideoFrames
    case destinationUnavailable
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message): message
        case let .permissionDenied(kind): "\(kind.title) permission is required."
        case let .captureFailed(message): "Capture failed: \(message)"
        case let .writerFailed(message): "Recording failed: \(message)"
        case .noPixelBufferPool: "The video encoder could not allocate its pixel-buffer pool."
        case .noVideoFrames: "No video frames were received from the selected source."
        case .destinationUnavailable: "The recording folder is unavailable."
        case .cancelled: "Recording was cancelled."
        }
    }
}
