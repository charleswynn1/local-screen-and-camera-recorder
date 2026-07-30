@preconcurrency import ScreenCaptureKit
import CoreMedia
import Foundation

public final class ScreenCaptureService: NSObject, ScreenSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let videoQueue = DispatchQueue(label: "com.charleswynn.localrecorder.screen.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.charleswynn.localrecorder.screen.audio", qos: .userInitiated)
    private let lock = NSLock()
    private var stream: SCStream?
    private var videoHandler: (@Sendable (VideoSample) -> Void)?
    private var audioHandler: (@Sendable (AudioSample) -> Void)?
    private var eventHandler: (@Sendable (PipelineEvent) -> Void)?
    private var isStopping = false

    public func start(
        target: ScreenCaptureTarget,
        configuration: ScreenSourceConfiguration,
        videoHandler: @escaping @Sendable (VideoSample) -> Void,
        audioHandler: @escaping @Sendable (AudioSample) -> Void,
        eventHandler: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        guard let filter = target.filter else {
            throw RecorderError.invalidConfiguration(
                "Select a live screen source before recording."
            )
        }
        self.videoHandler = videoHandler
        self.audioHandler = audioHandler
        self.eventHandler = eventHandler
        isStopping = false

        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = Int(configuration.outputSize.width)
        streamConfiguration.height = Int(configuration.outputSize.height)
        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: configuration.framesPerSecond
        )
        streamConfiguration.queueDepth = 5
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfiguration.scalesToFit = true
        streamConfiguration.preservesAspectRatio = true
        streamConfiguration.showsCursor = configuration.showsCursor
        streamConfiguration.showMouseClicks = configuration.showsMouseClicks
        streamConfiguration.capturesAudio = configuration.capturesSystemAudio
        streamConfiguration.excludesCurrentProcessAudio = true
        streamConfiguration.sampleRate = 48_000
        streamConfiguration.channelCount = 2
        streamConfiguration.captureDynamicRange = .SDR
        if let sourceRect = target.sourceRectInPoints {
            streamConfiguration.sourceRect = sourceRect
        }

        let stream = SCStream(
            filter: filter,
            configuration: streamConfiguration,
            delegate: self
        )
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if configuration.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        self.stream = stream
        try await stream.startCapture()
    }

    public func stop() async {
        let stream = lock.withLock { () -> SCStream? in
            isStopping = true
            let current = self.stream
            self.stream = nil
            return current
        }
        try? await stream?.stopCapture()
        videoHandler = nil
        audioHandler = nil
    }

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch outputType {
        case .screen:
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            videoHandler?(VideoSample(sampleBuffer))
        case .audio:
            audioHandler?(AudioSample(source: .system, sampleBuffer: sampleBuffer))
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let stopping = lock.withLock { isStopping }
        guard !stopping else { return }
        eventHandler?(.stopRequested("Screen capture stopped: \(error.localizedDescription)"))
    }
}
