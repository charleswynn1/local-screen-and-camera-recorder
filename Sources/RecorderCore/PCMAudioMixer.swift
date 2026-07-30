@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

public final class PCMAudioMixer: AudioMixer, @unchecked Sendable {
    public static let sampleRate: Int32 = 48_000
    public static let channelCount: Int = 2

    private struct Chunk {
        let startFrame: Int64
        let samples: [Float]

        var frameCount: Int { samples.count / channelCount }
        var endFrame: Int64 { startFrame + Int64(frameCount) }
    }

    private struct Track {
        var chunks = [Chunk]()
        var latestEndFrame: Int64?

        mutating func insert(_ chunk: Chunk) {
            chunks.append(chunk)
            chunks.sort { $0.startFrame < $1.startFrame }
            latestEndFrame = max(latestEndFrame ?? chunk.endFrame, chunk.endFrame)
        }

        mutating func read(startFrame: Int64, frameCount: Int) -> [Float] {
            var result = [Float](repeating: 0, count: frameCount * channelCount)
            let endFrame = startFrame + Int64(frameCount)
            for chunk in chunks {
                let copyStart = max(startFrame, chunk.startFrame)
                let copyEnd = min(endFrame, chunk.endFrame)
                guard copyStart < copyEnd else { continue }
                let sourceOffset = Int(copyStart - chunk.startFrame) * channelCount
                let destinationOffset = Int(copyStart - startFrame) * channelCount
                let count = Int(copyEnd - copyStart) * channelCount
                result.replaceSubrange(
                    destinationOffset..<(destinationOffset + count),
                    with: chunk.samples[sourceOffset..<(sourceOffset + count)]
                )
            }
            chunks.removeAll { $0.endFrame <= endFrame }
            return result
        }
    }

    private let lock = NSLock()
    private let includesSystemAudio: Bool
    private let includesMicrophone: Bool
    private var systemTrack = Track()
    private var microphoneTrack = Track()
    private var nextOutputFrame: Int64 = 0
    private let maximumLeadFrames = Int64(sampleRate / 4)
    private let blockSize = 1_024

    public init(includesSystemAudio: Bool, includesMicrophone: Bool) {
        self.includesSystemAudio = includesSystemAudio
        self.includesMicrophone = includesMicrophone
    }

    public static func normalizedPowerLevel(from sampleBuffer: CMSampleBuffer) -> Double {
        guard let samples = try? extractStereoFloatSamples(from: sampleBuffer),
              !samples.isEmpty else {
            return 0
        }
        let meanSquare = samples.reduce(0.0) {
            $0 + Double($1 * $1)
        } / Double(samples.count)
        let rootMeanSquare = sqrt(meanSquare)
        let decibels = 20 * log10(max(rootMeanSquare, 0.000_01))
        return min(1, max(0, (decibels + 60) / 60))
    }

    public func ingest(
        _ sample: AudioSample,
        normalizedPTS: CMTime
    ) throws -> [CMSampleBuffer] {
        let samples = try Self.extractStereoFloatSamples(from: sample.sampleBuffer)
        guard !samples.isEmpty else { return [] }
        let startFrame = max(
            0,
            Int64((normalizedPTS.seconds * Double(Self.sampleRate)).rounded())
        )
        let chunk = Chunk(startFrame: startFrame, samples: samples)

        return try lock.withLock {
            switch sample.source {
            case .system:
                guard includesSystemAudio else { return [] }
                systemTrack.insert(chunk)
            case .microphone:
                guard includesMicrophone else { return [] }
                microphoneTrack.insert(chunk)
            }
            return try drain(finishing: false)
        }
    }

    public func finish() throws -> [CMSampleBuffer] {
        try lock.withLock {
            try drain(finishing: true)
        }
    }

    private func drain(finishing: Bool) throws -> [CMSampleBuffer] {
        guard let watermark = outputWatermark(finishing: finishing) else { return [] }
        var output = [CMSampleBuffer]()
        while nextOutputFrame < watermark {
            let frames = min(blockSize, Int(watermark - nextOutputFrame))
            let systemSamples = systemTrack.read(startFrame: nextOutputFrame, frameCount: frames)
            let microphoneSamples = microphoneTrack.read(startFrame: nextOutputFrame, frameCount: frames)
            var mixed = [Float](repeating: 0, count: frames * Self.channelCount)

            let systemGain: Float = includesSystemAudio && includesMicrophone ? 0.5 : 1
            let microphoneGain: Float = 1
            for index in mixed.indices {
                let system = includesSystemAudio ? systemSamples[index] * systemGain : 0
                let microphone = includesMicrophone ? microphoneSamples[index] * microphoneGain : 0
                mixed[index] = min(0.891_251, max(-0.891_251, system + microphone))
            }

            output.append(try Self.makeSampleBuffer(samples: mixed, startFrame: nextOutputFrame))
            nextOutputFrame += Int64(frames)
        }
        return output
    }

    private func outputWatermark(finishing: Bool) -> Int64? {
        let systemEnd = includesSystemAudio ? systemTrack.latestEndFrame : nil
        let microphoneEnd = includesMicrophone ? microphoneTrack.latestEndFrame : nil

        if finishing {
            return [systemEnd, microphoneEnd].compactMap { $0 }.max()
        }
        switch (includesSystemAudio, includesMicrophone) {
        case (true, true):
            if systemEnd == nil || microphoneEnd == nil {
                guard let availableEnd = systemEnd ?? microphoneEnd else { return nil }
                return max(0, availableEnd - maximumLeadFrames)
            }
            guard let systemEnd, let microphoneEnd else { return nil }
            let natural = min(systemEnd, microphoneEnd)
            let forced = max(systemEnd, microphoneEnd) - maximumLeadFrames
            return max(natural, forced)
        case (true, false):
            return systemEnd
        case (false, true):
            return microphoneEnd
        case (false, false):
            return nil
        }
    }

    public static func audioFormatDescription() throws -> CMAudioFormatDescription {
        var description: CMAudioFormatDescription?
        var asbd = outputASBD
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw RecorderError.writerFailed("Could not create the audio format description (\(status)).")
        }
        return description
    }

    private static var outputASBD: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channelCount * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channelCount * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    static func extractStereoFloatSamples(from sampleBuffer: CMSampleBuffer) throws -> [Float] {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw RecorderError.captureFailed("An audio sample did not include a valid format.")
        }
        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate > 0,
              asbd.mChannelsPerFrame > 0 else {
            throw RecorderError.captureFailed("Only linear PCM capture audio is supported.")
        }

        let inputFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard inputFrames > 0 else { return [] }
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let inputChannels = Int(asbd.mChannelsPerFrame)
        let native = try sampleBuffer.withAudioBufferList(
            flags: [.audioBufferListAssure16ByteAlignment]
        ) { buffers, _ -> [Float] in
            var native = [Float](repeating: 0, count: inputFrames * channelCount)

            func sample(bufferIndex: Int, sampleIndex: Int) -> Float {
                guard bufferIndex < buffers.count, let data = buffers[bufferIndex].mData else { return 0 }
                if isFloat && asbd.mBitsPerChannel == 32 {
                    return data.assumingMemoryBound(to: Float.self)[sampleIndex]
                }
                if isFloat && asbd.mBitsPerChannel == 64 {
                    return Float(data.assumingMemoryBound(to: Double.self)[sampleIndex])
                }
                if isSignedInteger && asbd.mBitsPerChannel == 16 {
                    return Float(data.assumingMemoryBound(to: Int16.self)[sampleIndex]) / Float(Int16.max)
                }
                if isSignedInteger && asbd.mBitsPerChannel == 32 {
                    return Float(data.assumingMemoryBound(to: Int32.self)[sampleIndex]) / Float(Int32.max)
                }
                return 0
            }

            for frame in 0..<inputFrames {
                for channel in 0..<channelCount {
                    let sourceChannel = min(channel, inputChannels - 1)
                    let bufferIndex = isNonInterleaved ? sourceChannel : 0
                    let sampleIndex = isNonInterleaved ? frame : frame * inputChannels + sourceChannel
                    native[frame * channelCount + channel] = sample(
                        bufferIndex: bufferIndex,
                        sampleIndex: sampleIndex
                    )
                }
            }
            return native
        }

        if abs(asbd.mSampleRate - Double(sampleRate)) < 0.5 {
            return native
        }
        return linearResample(
            native,
            inputFrames: inputFrames,
            inputRate: asbd.mSampleRate,
            outputRate: Double(sampleRate)
        )
    }

    private static func linearResample(
        _ input: [Float],
        inputFrames: Int,
        inputRate: Double,
        outputRate: Double
    ) -> [Float] {
        let outputFrames = max(1, Int((Double(inputFrames) * outputRate / inputRate).rounded()))
        var output = [Float](repeating: 0, count: outputFrames * channelCount)
        let ratio = inputRate / outputRate
        for outputFrame in 0..<outputFrames {
            let sourcePosition = min(Double(inputFrames - 1), Double(outputFrame) * ratio)
            let lower = Int(sourcePosition.rounded(.down))
            let upper = min(inputFrames - 1, lower + 1)
            let fraction = Float(sourcePosition - Double(lower))
            for channel in 0..<channelCount {
                let lowerSample = input[lower * channelCount + channel]
                let upperSample = input[upper * channelCount + channel]
                output[outputFrame * channelCount + channel] =
                    lowerSample + (upperSample - lowerSample) * fraction
            }
        }
        return output
    }

    static func makeSampleBuffer(
        samples: [Float],
        startFrame: Int64
    ) throws -> CMSampleBuffer {
        let frameCount = samples.count / channelCount
        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw RecorderError.writerFailed("Could not allocate a mixed audio buffer (\(status)).")
        }
        status = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw RecorderError.writerFailed("Could not populate a mixed audio buffer (\(status)).")
        }

        let format = try audioFormatDescription()
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: CMTime(value: startFrame, timescale: sampleRate),
            decodeTimeStamp: .invalid
        )
        var sampleSize = channelCount * MemoryLayout<Float>.size
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw RecorderError.writerFailed("Could not create a mixed audio sample (\(status)).")
        }
        return sampleBuffer
    }
}
