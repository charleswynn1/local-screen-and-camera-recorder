@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@testable import RecorderCore
import Testing

extension RecorderCoreTestPlan {
@Suite("Asset writer integration", .serialized)
struct AssetWriterIntegrationTests {
    @Test
    func writerProducesPlayableH264MP4() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalRecorderWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let writer = try AssetRecordingWriter(
            destinationFolder: folder,
            outputSize: CGSize(width: 640, height: 360),
            preset: .compact,
            includesAudio: false,
            now: Date(timeIntervalSince1970: 0)
        )
        try writer.start()
        guard let pool = writer.pixelBufferPool else {
            Issue.record("Writer did not create a pixel buffer pool")
            return
        }

        for frameIndex in 0..<30 {
            var pixelBuffer: CVPixelBuffer?
            #expect(
                CVPixelBufferPoolCreatePixelBuffer(
                    kCFAllocatorDefault,
                    pool,
                    &pixelBuffer
                ) == kCVReturnSuccess
            )
            guard let pixelBuffer else { continue }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(
                    base,
                    Int32(frameIndex * 3),
                    CVPixelBufferGetBytesPerRow(pixelBuffer)
                        * CVPixelBufferGetHeight(pixelBuffer)
                )
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            var accepted = false
            for _ in 0..<200 {
                if writer.appendVideo(
                    pixelBuffer,
                    at: CMTime(value: CMTimeValue(frameIndex), timescale: 30)
                ) {
                    accepted = true
                    break
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(accepted)
        }

        let url = try await writer.finish()
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.pathExtension == "mp4")

        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        #expect(videoTracks.count == 1)
        #expect(audioTracks.count == 0)
        #expect(duration.seconds > 0.8)
        let size = try await videoTracks[0].load(.naturalSize)
        #expect(size == CGSize(width: 640, height: 360))

        let trashMover = RecordingTrashSpy()
        let library = LocalRecordingLibrary(
            trashMover: trashMover
        )
        let recordings = try await library.recordings(in: folder)
        #expect(recordings.count == 1)
        let renamed = try await library.rename(
            recordings[0],
            to: "Renamed Fixture"
        )
        #expect(renamed.url.lastPathComponent == "Renamed Fixture.mp4")
        #expect(FileManager.default.fileExists(atPath: renamed.url.path))
        #expect(try await library.recordings(in: folder).count == 1)
        try await library.moveToTrash(renamed)
        #expect(trashMover.urls == [renamed.url])
    }

    @Test
    func writerProducesH264AACWithContinuousAudioTimestamps() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalRecorderAVFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let writer = try AssetRecordingWriter(
            destinationFolder: folder,
            outputSize: CGSize(width: 320, height: 180),
            preset: .compact,
            includesAudio: true,
            now: Date(timeIntervalSince1970: 1)
        )
        try writer.start()
        let pool = try #require(writer.pixelBufferPool)

        for frameIndex in 0..<30 {
            var pixelBuffer: CVPixelBuffer?
            #expect(
                CVPixelBufferPoolCreatePixelBuffer(
                    kCFAllocatorDefault,
                    pool,
                    &pixelBuffer
                ) == kCVReturnSuccess
            )
            let buffer = try #require(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(
                    base,
                    Int32((frameIndex * 7) % 255),
                    CVPixelBufferGetBytesPerRow(buffer)
                        * CVPixelBufferGetHeight(buffer)
                )
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(
                await appendVideo(
                    buffer,
                    frameIndex: frameIndex,
                    writer: writer
                )
            )
        }

        var startFrame: Int64 = 0
        while startFrame < 48_000 {
            let frameCount = min(1_024, 48_000 - Int(startFrame))
            var samples = [Float]()
            samples.reserveCapacity(frameCount * 2)
            for offset in 0..<frameCount {
                let time = Double(startFrame + Int64(offset)) / 48_000
                let sample = Float(sin(2 * .pi * 440 * time) * 0.1)
                samples.append(sample)
                samples.append(sample)
            }
            let sampleBuffer = try PCMAudioMixer.makeSampleBuffer(
                samples: samples,
                startFrame: startFrame
            )
            #expect(
                await appendAudio(
                    sampleBuffer,
                    writer: writer
                )
            )
            startFrame += Int64(frameCount)
        }

        let url = try await writer.finish()
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(videoTracks.count == 1)
        #expect(audioTracks.count == 1)

        let videoDescriptions = try await videoTracks[0].load(
            .formatDescriptions
        )
        let audioDescriptions = try await audioTracks[0].load(
            .formatDescriptions
        )
        #expect(
            videoDescriptions.contains {
                CMFormatDescriptionGetMediaSubType($0)
                    == kCMVideoCodecType_H264
            }
        )
        #expect(
            audioDescriptions.contains {
                CMFormatDescriptionGetMediaSubType($0)
                    == kAudioFormatMPEG4AAC
            }
        )
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 0.9)
        #expect(duration.seconds < 1.1)
        try verifyContinuousSamples(
            asset: asset,
            track: audioTracks[0],
            maximumGap: 0.003
        )
    }

    @Test
    func recoveryPublishesPlayableInterruptedFragment() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalRecorderRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let writer = try AssetRecordingWriter(
            destinationFolder: folder,
            outputSize: CGSize(width: 320, height: 180),
            preset: .compact,
            includesAudio: false
        )
        try writer.start()
        guard let pool = writer.pixelBufferPool else {
            Issue.record("Writer did not create a pixel buffer pool")
            return
        }
        for frameIndex in 0..<6 {
            var pixelBuffer: CVPixelBuffer?
            #expect(
                CVPixelBufferPoolCreatePixelBuffer(
                    kCFAllocatorDefault,
                    pool,
                    &pixelBuffer
                ) == kCVReturnSuccess
            )
            guard let pixelBuffer else { continue }
            var accepted = false
            for _ in 0..<200 {
                if writer.appendVideo(
                    pixelBuffer,
                    at: CMTime(value: CMTimeValue(frameIndex), timescale: 6)
                ) {
                    accepted = true
                    break
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(accepted)
        }
        let complete = try await writer.finish()
        let partial = folder.appendingPathComponent(
            ".Local Recorder fixture.part.mp4"
        )
        try FileManager.default.moveItem(at: complete, to: partial)
        let invalid = folder.appendingPathComponent(
            ".Local Recorder invalid.part.mp4"
        )
        try Data("not an MP4".utf8).write(to: invalid)

        let report = await InterruptedRecordingRecovery().recover(in: folder)
        #expect(report.recovered.count == 1)
        #expect(
            report.invalid.map {
                $0.resolvingSymlinksInPath()
            } == [invalid.resolvingSymlinksInPath()]
        )
        #expect(report.recovered[0].lastPathComponent.hasPrefix("Local Recorder Recovered"))
    }

    private func appendVideo(
        _ buffer: CVPixelBuffer,
        frameIndex: Int,
        writer: AssetRecordingWriter
    ) async -> Bool {
        for _ in 0..<200 {
            if writer.appendVideo(
                buffer,
                at: CMTime(value: CMTimeValue(frameIndex), timescale: 30)
            ) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    private func appendAudio(
        _ sampleBuffer: CMSampleBuffer,
        writer: AssetRecordingWriter
    ) async -> Bool {
        for _ in 0..<200 {
            if writer.appendAudio(sampleBuffer) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    private func verifyContinuousSamples(
        asset: AVAsset,
        track: AVAssetTrack,
        maximumGap: TimeInterval
    ) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        guard reader.canAdd(output) else {
            Issue.record("AVAssetReader rejected the fixture audio track")
            return
        }
        reader.add(output)
        #expect(reader.startReading())

        var previousEnd: CMTime?
        var sampleCount = 0
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else {
                continue
            }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(
                sample
            )
            let duration = CMSampleBufferGetDuration(sample)
            #expect(presentationTime.isNumeric)
            guard presentationTime.isNumeric else { continue }
            if let previousEnd {
                let gap = CMTimeSubtract(
                    presentationTime,
                    previousEnd
                ).seconds
                #expect(abs(gap) <= maximumGap)
            }
            if duration.isNumeric {
                previousEnd = CMTimeAdd(presentationTime, duration)
            } else {
                previousEnd = presentationTime
            }
            sampleCount += 1
        }
        #expect(sampleCount > 0)
        #expect(reader.status == .completed)
    }
}
}

private final class RecordingTrashSpy:
    TrashMoving,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage = [URL]()

    var urls: [URL] {
        lock.withLock { storage }
    }

    func moveToTrash(_ url: URL) throws {
        lock.withLock {
            storage.append(url)
        }
    }
}
