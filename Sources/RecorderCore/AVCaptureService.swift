@preconcurrency import AVFoundation
import CoreMedia
import Foundation

public final class AVCameraCaptureService:
    NSObject,
    CameraSource,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(
        label: "com.charleswynn.localrecorder.camera.session"
    )
    private let videoQueue = DispatchQueue(
        label: "com.charleswynn.localrecorder.camera.video",
        qos: .userInteractive
    )
    private let videoOutput = AVCaptureVideoDataOutput()
    private let lock = NSLock()
    private var videoHandler: (@Sendable (VideoSample) -> Void)?
    private var eventHandler: (@Sendable (PipelineEvent) -> Void)?
    private var activeDeviceID: String?
    private var observers = [NSObjectProtocol]()

    public func start(
        cameraDeviceID: String?,
        maximumVideoSize: CGSize,
        framesPerSecond: Int32,
        videoHandler: @escaping @Sendable (VideoSample) -> Void,
        eventHandler: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        lock.withLock {
            self.videoHandler = videoHandler
            self.eventHandler = eventHandler
        }
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                sessionQueue.async { [self] in
                    do {
                        let deviceID = try configure(
                            cameraDeviceID: cameraDeviceID,
                            maximumVideoSize: maximumVideoSize,
                            framesPerSecond: framesPerSecond
                        )
                        lock.withLock {
                            activeDeviceID = deviceID
                        }
                        session.startRunning()
                        guard session.isRunning else {
                            throw RecorderError.captureFailed(
                                "The selected camera did not start."
                            )
                        }
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            installObservers()
        } catch {
            await stop()
            throw error
        }
    }

    public func stop() async {
        removeObservers()
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                if session.isRunning {
                    session.stopRunning()
                }
                session.beginConfiguration()
                for input in session.inputs {
                    session.removeInput(input)
                }
                for output in session.outputs {
                    session.removeOutput(output)
                }
                session.commitConfiguration()
                lock.withLock {
                    activeDeviceID = nil
                    videoHandler = nil
                    eventHandler = nil
                }
                continuation.resume()
            }
        }
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }
        let handler = lock.withLock { videoHandler }
        handler?(VideoSample(sampleBuffer))
    }

    private func configure(
        cameraDeviceID: String?,
        maximumVideoSize: CGSize,
        framesPerSecond: Int32
    ) throws -> String {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }

        guard let camera = cameraDeviceID.flatMap(
            AVCaptureDevice.init(uniqueID:)
        )
            ?? AVCaptureDevice.systemPreferredCamera
            ?? AVCaptureDevice.default(for: .video) else {
            throw RecorderError.invalidConfiguration(
                ConfigurationIssue.missingCamera.message
            )
        }
        try configure(
            camera: camera,
            maximumVideoSize: maximumVideoSize,
            requestedFrameRate: framesPerSecond
        )
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            throw RecorderError.captureFailed(
                "The selected camera cannot be added to the capture session."
            )
        }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else {
            throw RecorderError.captureFailed(
                "The camera video output is unavailable."
            )
        }
        session.addOutput(videoOutput)
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }
        return camera.uniqueID
    }

    private func configure(
        camera: AVCaptureDevice,
        maximumVideoSize: CGSize,
        requestedFrameRate: Int32
    ) throws {
        struct Candidate {
            let format: AVCaptureDevice.Format
            let dimensions: CMVideoDimensions
            let frameRate: Double
            let supportsSRGB: Bool
        }

        let requested = Double(requestedFrameRate)
        let candidates = camera.formats.compactMap {
            format -> Candidate? in
            let dimensions = CMVideoFormatDescriptionGetDimensions(
                format.formatDescription
            )
            guard dimensions.width <= Int32(maximumVideoSize.width),
                  dimensions.height <= Int32(maximumVideoSize.height),
                  format.videoSupportedFrameRateRanges.contains(where: {
                        $0.minFrameRate <= requested + 0.1
                            && $0.maxFrameRate + 0.1 >= requested
                    }) else {
                return nil
            }
            return Candidate(
                format: format,
                dimensions: dimensions,
                frameRate: requested,
                supportsSRGB: format.supportedColorSpaces.contains(.sRGB)
            )
        }
        guard let candidate = candidates.max(by: {
            if $0.supportsSRGB != $1.supportsSRGB {
                return !$0.supportsSRGB && $1.supportsSRGB
            }
            let lhsRateMatch = $0.frameRate + 0.01 >= requested
            let rhsRateMatch = $1.frameRate + 0.01 >= requested
            if lhsRateMatch != rhsRateMatch {
                return !lhsRateMatch && rhsRateMatch
            }
            let lhsArea = Int64($0.dimensions.width)
                * Int64($0.dimensions.height)
            let rhsArea = Int64($1.dimensions.width)
                * Int64($1.dimensions.height)
            return lhsArea < rhsArea
        }) else {
            throw RecorderError.captureFailed(
                "The selected camera has no format compatible with the output size."
            )
        }

        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }
        camera.activeFormat = candidate.format
        if candidate.supportsSRGB {
            camera.activeColorSpace = .sRGB
        }
        let duration = CMTime(
            seconds: 1 / max(1, candidate.frameRate),
            preferredTimescale: 60_000
        )
        camera.activeVideoMinFrameDuration = duration
        camera.activeVideoMaxFrameDuration = duration
    }

    private func installObservers() {
        removeObservers()
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let self,
                      let device = notification.object as? AVCaptureDevice,
                      device.uniqueID == lock.withLock({
                          activeDeviceID
                      }) else {
                    return
                }
                emit(
                    .stopRequested(
                        "Camera “\(device.localizedName)” disconnected."
                    )
                )
            }
        )
        for name in [
            AVCaptureSession.runtimeErrorNotification,
            AVCaptureSession.wasInterruptedNotification
        ] {
            observers.append(
                center.addObserver(
                    forName: name,
                    object: session,
                    queue: nil
                ) { [weak self] notification in
                    let detail = (
                        notification.userInfo?[
                            AVCaptureSessionErrorKey
                        ] as? Error
                    )?.localizedDescription
                    self?.emit(
                        .stopRequested(
                            detail.map {
                                "Camera capture stopped: \($0)"
                            } ?? "Camera capture was interrupted."
                        )
                    )
                }
            )
        }
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func emit(_ event: PipelineEvent) {
        let handler = lock.withLock { eventHandler }
        handler?(event)
    }
}

public final class AVMicrophoneCaptureService:
    NSObject,
    MicrophoneSource,
    AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(
        label: "com.charleswynn.localrecorder.microphone.session"
    )
    private let audioQueue = DispatchQueue(
        label: "com.charleswynn.localrecorder.microphone.audio",
        qos: .userInitiated
    )
    private let audioOutput = AVCaptureAudioDataOutput()
    private let lock = NSLock()
    private var audioHandler: (@Sendable (AudioSample) -> Void)?
    private var eventHandler: (@Sendable (PipelineEvent) -> Void)?
    private var activeDeviceID: String?
    private var observers = [NSObjectProtocol]()

    public func start(
        microphoneDeviceID: String?,
        audioHandler: @escaping @Sendable (AudioSample) -> Void,
        eventHandler: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        lock.withLock {
            self.audioHandler = audioHandler
            self.eventHandler = eventHandler
        }
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                sessionQueue.async { [self] in
                    do {
                        let deviceID = try configure(
                            microphoneDeviceID: microphoneDeviceID
                        )
                        lock.withLock {
                            activeDeviceID = deviceID
                        }
                        session.startRunning()
                        guard session.isRunning else {
                            throw RecorderError.captureFailed(
                                "The selected microphone did not start."
                            )
                        }
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            installObservers()
        } catch {
            await stop()
            throw error
        }
    }

    public func stop() async {
        removeObservers()
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                if session.isRunning {
                    session.stopRunning()
                }
                session.beginConfiguration()
                for input in session.inputs {
                    session.removeInput(input)
                }
                for output in session.outputs {
                    session.removeOutput(output)
                }
                session.commitConfiguration()
                lock.withLock {
                    activeDeviceID = nil
                    audioHandler = nil
                    eventHandler = nil
                }
                continuation.resume()
            }
        }
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }
        let handler = lock.withLock { audioHandler }
        handler?(
            AudioSample(
                source: .microphone,
                sampleBuffer: sampleBuffer
            )
        )
    }

    private func configure(
        microphoneDeviceID: String?
    ) throws -> String {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }

        guard let microphone = microphoneDeviceID.flatMap(
            AVCaptureDevice.init(uniqueID:)
        ) ?? AVCaptureDevice.default(for: .audio) else {
            throw RecorderError.invalidConfiguration(
                ConfigurationIssue.missingMicrophone.message
            )
        }
        let input = try AVCaptureDeviceInput(device: microphone)
        guard session.canAddInput(input) else {
            throw RecorderError.captureFailed(
                "The selected microphone cannot be added to the capture session."
            )
        }
        session.addInput(input)

        audioOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        guard session.canAddOutput(audioOutput) else {
            throw RecorderError.captureFailed(
                "The microphone audio output is unavailable."
            )
        }
        session.addOutput(audioOutput)
        return microphone.uniqueID
    }

    private func installObservers() {
        removeObservers()
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let self,
                      let device = notification.object as? AVCaptureDevice,
                      device.uniqueID == lock.withLock({
                          activeDeviceID
                      }) else {
                    return
                }
                emit(
                    .warning(
                        "Microphone “\(device.localizedName)” disconnected. Recording will continue without it."
                    )
                )
            }
        )
        for name in [
            AVCaptureSession.runtimeErrorNotification,
            AVCaptureSession.wasInterruptedNotification
        ] {
            observers.append(
                center.addObserver(
                    forName: name,
                    object: session,
                    queue: nil
                ) { [weak self] notification in
                    let detail = (
                        notification.userInfo?[
                            AVCaptureSessionErrorKey
                        ] as? Error
                    )?.localizedDescription
                    self?.emit(
                        .warning(
                            detail.map {
                                "Microphone capture stopped: \($0)"
                            } ?? "Microphone capture was interrupted. Video recording will continue."
                        )
                    )
                }
            )
        }
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func emit(_ event: PipelineEvent) {
        let handler = lock.withLock { eventHandler }
        handler?(event)
    }
}
