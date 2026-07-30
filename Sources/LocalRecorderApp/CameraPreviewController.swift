@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import AppKit
import CoreMedia
import Foundation
import RecorderCore
import SwiftUI

final class CameraPreviewController: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.charleswynn.localrecorder.preview.camera")
    private var activeDeviceID: String?

    func start(deviceID: String?) async throws {
        guard activeDeviceID != deviceID || !session.isRunning else { return }
        await stop()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    let activeDeviceID = try CaptureSessionTransaction
                        .configureAndStart(session) {
                            session.sessionPreset = .high
                            for input in session.inputs {
                                session.removeInput(input)
                            }
                            let camera = deviceID.flatMap(
                                AVCaptureDevice.init(uniqueID:)
                            )
                                ?? AVCaptureDevice.systemPreferredCamera
                                ?? AVCaptureDevice.default(for: .video)
                            guard let camera else {
                                throw RecorderError.invalidConfiguration(
                                    ConfigurationIssue.missingCamera.message
                                )
                            }
                            let input = try AVCaptureDeviceInput(
                                device: camera
                            )
                            guard session.canAddInput(input) else {
                                throw RecorderError.captureFailed(
                                    "The selected camera cannot be previewed."
                                )
                            }
                            session.addInput(input)
                            return camera.uniqueID
                        }
                    self.activeDeviceID = activeDeviceID
                    guard session.isRunning else {
                        throw RecorderError.captureFailed(
                            "The selected camera preview did not start."
                        )
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if session.isRunning {
                    session.stopRunning()
                }
                activeDeviceID = nil
                continuation.resume()
            }
        }
    }
}

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraLayerView {
        let view = CameraLayerView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: CameraLayerView, context: Context) {
        nsView.previewLayer.session = session
        nsView.previewLayer.videoGravity = .resizeAspectFill
        if let connection = nsView.previewLayer.connection,
           connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }
}

final class CameraLayerView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = previewLayer
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

final class MicrophoneMeterController: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(
        label: "com.charleswynn.localrecorder.meter.microphone.session"
    )
    private let sampleQueue = DispatchQueue(
        label: "com.charleswynn.localrecorder.meter.microphone.samples",
        qos: .utility
    )
    private let handlerLock = NSLock()
    private var activeDeviceID: String?
    private var levelHandler: (@Sendable (Double) -> Void)?
    private var lastEmission = ContinuousClock.now

    func start(
        deviceID: String?,
        levelHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        if session.isRunning, activeDeviceID == deviceID {
            handlerLock.withLock {
                self.levelHandler = levelHandler
            }
            return
        }
        await stop()
        handlerLock.withLock {
            self.levelHandler = levelHandler
        }
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                do {
                    let activeDeviceID = try CaptureSessionTransaction
                        .configureAndStart(session) {
                            session.sessionPreset = .high
                            for input in session.inputs {
                                session.removeInput(input)
                            }
                            for existingOutput in session.outputs {
                                session.removeOutput(existingOutput)
                            }
                            let device = deviceID.flatMap(
                                AVCaptureDevice.init(uniqueID:)
                            )
                                ?? AVCaptureDevice.default(for: .audio)
                            guard let device else {
                                throw RecorderError.invalidConfiguration(
                                    ConfigurationIssue
                                        .missingMicrophone
                                        .message
                                )
                            }
                            let input = try AVCaptureDeviceInput(
                                device: device
                            )
                            guard session.canAddInput(input) else {
                                throw RecorderError.captureFailed(
                                    "The selected microphone cannot be monitored."
                                )
                            }
                            session.addInput(input)
                            output.audioSettings = [
                                AVFormatIDKey: kAudioFormatLinearPCM,
                                AVSampleRateKey: 48_000,
                                AVNumberOfChannelsKey: 2,
                                AVLinearPCMBitDepthKey: 32,
                                AVLinearPCMIsFloatKey: true,
                                AVLinearPCMIsNonInterleaved: false
                            ]
                            output.setSampleBufferDelegate(
                                self,
                                queue: sampleQueue
                            )
                            guard session.canAddOutput(output) else {
                                throw RecorderError.captureFailed(
                                    "The microphone level output is unavailable."
                                )
                            }
                            session.addOutput(output)
                            return device.uniqueID
                        }
                    self.activeDeviceID = activeDeviceID
                    guard session.isRunning else {
                        throw RecorderError.captureFailed(
                            "The microphone level monitor did not start."
                        )
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                if session.isRunning {
                    session.stopRunning()
                }
                activeDeviceID = nil
                let handler = handlerLock.withLock { () -> (@Sendable (Double) -> Void)? in
                    let handler = levelHandler
                    levelHandler = nil
                    return handler
                }
                handler?(0)
                continuation.resume()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = ContinuousClock.now
        guard now - lastEmission >= .milliseconds(60) else { return }
        lastEmission = now
        let handler = handlerLock.withLock { levelHandler }
        handler?(PCMAudioMixer.normalizedPowerLevel(from: sampleBuffer))
    }
}

final class SystemAudioMeterController: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let audioQueue = DispatchQueue(
        label: "com.charleswynn.localrecorder.meter.system-audio",
        qos: .utility
    )
    private let videoQueue = DispatchQueue(
        label: "com.charleswynn.localrecorder.meter.system-video",
        qos: .utility
    )
    private let lock = NSLock()
    private var stream: SCStream?
    private var activeTarget: ScreenCaptureTarget?
    private var levelHandler: (@Sendable (Double) -> Void)?
    private var lastEmission = ContinuousClock.now

    func start(
        target: ScreenCaptureTarget,
        levelHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let filter = target.filter else {
            throw RecorderError.invalidConfiguration(
                "Select a live screen source before monitoring its audio."
            )
        }
        if lock.withLock({ self.stream != nil && activeTarget === target }) {
            lock.withLock {
                self.levelHandler = levelHandler
            }
            return
        }
        await stop()
        lock.withLock {
            self.levelHandler = levelHandler
        }

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        configuration.queueDepth = 1
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.showsCursor = false
        if let sourceRect = target.sourceRectInPoints {
            configuration.sourceRect = sourceRect
        }

        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: videoQueue
        )
        try stream.addStreamOutput(
            self,
            type: .audio,
            sampleHandlerQueue: audioQueue
        )
        lock.withLock {
            self.stream = stream
            activeTarget = target
        }
        do {
            try await stream.startCapture()
        } catch {
            lock.withLock {
                self.stream = nil
                activeTarget = nil
            }
            throw error
        }
    }

    func stop() async {
        let (stream, handler) = lock.withLock {
            let stream = self.stream
            self.stream = nil
            activeTarget = nil
            let handler = levelHandler
            levelHandler = nil
            return (stream, handler)
        }
        try? await stream?.stopCapture()
        handler?(0)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio else { return }
        let now = ContinuousClock.now
        guard now - lastEmission >= .milliseconds(60) else { return }
        lastEmission = now
        let handler = lock.withLock { levelHandler }
        handler?(PCMAudioMixer.normalizedPowerLevel(from: sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let handler = lock.withLock { levelHandler }
        handler?(0)
    }
}
