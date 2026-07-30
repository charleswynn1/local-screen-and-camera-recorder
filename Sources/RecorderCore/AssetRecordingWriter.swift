@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public final class AssetRecordingWriter: RecordingWriter, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.charleswynn.localrecorder.writer", qos: .userInitiated)
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let stagingURL: URL
    private let finalURL: URL
    private let fileManager: FileManager
    private let expectedOutputSize: CGSize
    private let frameDuration: CMTime
    private var hasVideo = false
    private var lastVideoPresentationTime = CMTime.zero
    private var lastAudioEndTime = CMTime.zero
    private var hasFinished = false

    public var pixelBufferPool: CVPixelBufferPool? {
        queue.sync { adaptor.pixelBufferPool }
    }

    public var failure: RecorderError? {
        queue.sync {
            guard writer.status == .failed else { return nil }
            return .writerFailed(
                writer.error?.localizedDescription ?? "The MP4 writer failed."
            )
        }
    }

    public init(
        destinationFolder: URL,
        outputSize: CGSize,
        preset: QualityPreset,
        includesAudio: Bool,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws {
        self.fileManager = fileManager
        expectedOutputSize = outputSize
        frameDuration = CMTime(
            value: 1,
            timescale: preset.framesPerSecond
        )
        guard outputSize.width >= 2, outputSize.height >= 2 else {
            throw RecorderError.invalidConfiguration(ConfigurationIssue.invalidOutputSize.message)
        }
        let urls = Self.makeOutputURLs(
            folder: destinationFolder,
            fileManager: fileManager,
            date: now
        )
        stagingURL = urls.staging
        finalURL = urls.final
        writer = try AVAssetWriter(outputURL: stagingURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: preset.videoBitRate,
            AVVideoExpectedSourceFrameRateKey: preset.framesPerSecond,
            AVVideoMaxKeyFrameIntervalKey: Int(preset.framesPerSecond * 2),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoAllowFrameReorderingKey: true
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw RecorderError.invalidConfiguration(
                preset == .high
                    ? ConfigurationIssue.highQualityUnavailable.message
                    : ConfigurationIssue.invalidOutputSize.message
            )
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw RecorderError.writerFailed("The H.264 video input cannot be added.")
        }
        writer.add(videoInput)

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(outputSize.width),
            kCVPixelBufferHeightKey as String: Int(outputSize.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: attributes
        )

        if includesAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: PCMAudioMixer.sampleRate,
                AVNumberOfChannelsKey: PCMAudioMixer.channelCount,
                AVEncoderBitRateKey: 192_000
            ]
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: audioSettings,
                sourceFormatHint: try PCMAudioMixer.audioFormatDescription()
            )
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecorderError.writerFailed("The AAC audio input cannot be added.")
            }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }
    }

    public func start() throws {
        try queue.sync {
            guard writer.startWriting() else {
                throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "The writer did not start.")
            }
            writer.startSession(atSourceTime: .zero)
        }
    }

    public func appendVideo(_ pixelBuffer: CVPixelBuffer, at presentationTime: CMTime) -> Bool {
        queue.sync {
            guard !hasFinished, writer.status == .writing, videoInput.isReadyForMoreMediaData else {
                return false
            }
            var time = max(
                presentationTime,
                lastVideoPresentationTime
            )
            if hasVideo, time <= lastVideoPresentationTime {
                time = CMTimeAdd(
                    lastVideoPresentationTime,
                    CMTime(value: 1, timescale: 60_000)
                )
            }
            let appended = adaptor.append(pixelBuffer, withPresentationTime: time)
            if appended {
                hasVideo = true
                lastVideoPresentationTime = time
            }
            return appended
        }
    }

    public func appendAudio(_ sampleBuffer: CMSampleBuffer) -> Bool {
        queue.sync {
            guard !hasFinished,
                  writer.status == .writing,
                  let audioInput,
                  audioInput.isReadyForMoreMediaData else {
                return false
            }
            let appended = audioInput.append(sampleBuffer)
            if appended {
                let start = CMSampleBufferGetPresentationTimeStamp(
                    sampleBuffer
                )
                let duration = CMSampleBufferGetDuration(sampleBuffer)
                let end = duration.isNumeric
                    ? CMTimeAdd(start, duration)
                    : start
                if end.isNumeric, end > lastAudioEndTime {
                    lastAudioEndTime = end
                }
            }
            return appended
        }
    }

    public func finish() async throws -> URL {
        let hasVideo = queue.sync { self.hasVideo }
        guard hasVideo else {
            cancel()
            throw RecorderError.noVideoFrames
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !hasFinished else {
                    continuation.resume(throwing: RecorderError.writerFailed("The writer already finished."))
                    return
                }
                hasFinished = true
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                let videoEnd = CMTimeAdd(
                    lastVideoPresentationTime,
                    frameDuration
                )
                writer.endSession(
                    atSourceTime: max(videoEnd, lastAudioEndTime)
                )
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: RecorderError.writerFailed(
                                writer.error?.localizedDescription ?? "The MP4 could not be finalized."
                            )
                        )
                    }
                }
            }
        }

        let asset = AVURLAsset(url: stagingURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard videoTracks.count == 1 else {
            throw RecorderError.writerFailed("The finalized MP4 must contain exactly one video track.")
        }
        let videoDescriptions = try await videoTracks[0].load(.formatDescriptions)
        guard videoDescriptions.contains(where: {
            CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264
        }) else {
            throw RecorderError.writerFailed("The finalized MP4 does not contain H.264 video.")
        }
        let naturalSize = try await videoTracks[0].load(.naturalSize)
        guard abs(naturalSize.width) == expectedOutputSize.width,
              abs(naturalSize.height) == expectedOutputSize.height else {
            throw RecorderError.writerFailed("The finalized MP4 has unexpected video dimensions.")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.count <= 1 else {
            throw RecorderError.writerFailed("The finalized MP4 contains more than one audio track.")
        }
        if let audioTrack = audioTracks.first {
            let audioDescriptions = try await audioTrack.load(.formatDescriptions)
            guard audioDescriptions.contains(where: {
                CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC
            }) else {
                throw RecorderError.writerFailed("The finalized MP4 audio track is not AAC.")
            }
        }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration > .zero else {
            throw RecorderError.writerFailed("The finalized MP4 has no playable duration.")
        }
        try fileManager.moveItem(at: stagingURL, to: finalURL)
        return finalURL
    }

    public func cancel() {
        queue.sync {
            guard !hasFinished else { return }
            hasFinished = true
            writer.cancelWriting()
            try? fileManager.removeItem(at: stagingURL)
        }
    }

    private static func makeOutputURLs(
        folder: URL,
        fileManager: FileManager,
        date: Date
    ) -> (staging: URL, final: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let baseName = "Local Recorder \(formatter.string(from: date))"
        var final = folder.appendingPathComponent(baseName).appendingPathExtension("mp4")
        var suffix = 2
        while fileManager.fileExists(atPath: final.path) {
            final = folder
                .appendingPathComponent("\(baseName) \(suffix)")
                .appendingPathExtension("mp4")
            suffix += 1
        }
        let staging = folder
            .appendingPathComponent(".Local Recorder \(UUID().uuidString).part")
            .appendingPathExtension("mp4")
        return (staging, final)
    }
}
