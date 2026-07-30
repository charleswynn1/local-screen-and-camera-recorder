import CoreGraphics
import Foundation
import VideoToolbox

public enum OutputGeometry {
    public static func outputSize(
        sourceSize: CGSize,
        preset: QualityPreset,
        cameraOnly: Bool = false
    ) -> CGSize {
        if cameraOnly {
            guard sourceSize.width > 0, sourceSize.height > 0 else {
                return .zero
            }
            let maximum = preset.maximumSize
            let width = min(
                maximum.width,
                sourceSize.width,
                min(maximum.height, sourceSize.height) * 16 / 9
            )
            return CGSize(
                width: even(width),
                height: even(width * 9 / 16)
            )
        }
        let source = sourceSize
        guard source.width > 0, source.height > 0 else { return .zero }

        let maximum = preset.maximumSize
        let scale = min(1, min(maximum.width / source.width, maximum.height / source.height))
        let scaled = CGSize(width: source.width * scale, height: source.height * scale)
        return CGSize(width: even(scaled.width), height: even(scaled.height))
    }

    public static func aspectFillTransform(from source: CGRect, to destination: CGRect) -> CGAffineTransform {
        guard source.width > 0, source.height > 0 else { return .identity }
        let scale = max(destination.width / source.width, destination.height / source.height)
        let scaledWidth = source.width * scale
        let scaledHeight = source.height * scale
        let x = destination.midX - scaledWidth / 2
        let y = destination.midY - scaledHeight / 2
        return CGAffineTransform(translationX: x, y: y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -source.minX, y: -source.minY)
    }

    public static func aspectFitTransform(from source: CGRect, to destination: CGRect) -> CGAffineTransform {
        guard source.width > 0, source.height > 0 else { return .identity }
        let scale = min(destination.width / source.width, destination.height / source.height)
        let scaledWidth = source.width * scale
        let scaledHeight = source.height * scale
        let x = destination.midX - scaledWidth / 2
        let y = destination.midY - scaledHeight / 2
        return CGAffineTransform(translationX: x, y: y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -source.minX, y: -source.minY)
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        let rounded = max(2, Int(value.rounded(.down)))
        return CGFloat(rounded - rounded % 2)
    }
}

public enum EncoderPreflight {
    public static func highQualityFailureReason(outputSize: CGSize) -> String? {
        guard outputSize.width > 0, outputSize.height > 0,
              outputSize.width <= CGFloat(Int32.max),
              outputSize.height <= CGFloat(Int32.max) else {
            return "High quality is unavailable because the selected source has an invalid output size."
        }

        var session: VTCompressionSession?
        let encoderSpecification = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
        ] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(outputSize.width),
            height: Int32(outputSize.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            return "This Mac cannot create a hardware H.264 encoder for High quality at \(Int(outputSize.width)) × \(Int(outputSize.height))."
        }
        defer { VTCompressionSessionInvalidate(session) }

        let frameRate = NSNumber(value: QualityPreset.high.framesPerSecond)
        let bitRate = NSNumber(value: QualityPreset.high.videoBitRate)
        let propertyStatuses = [
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_ExpectedFrameRate,
                value: frameRate
            ),
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_AverageBitRate,
                value: bitRate
            ),
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_ProfileLevel,
                value: kVTProfileLevel_H264_High_AutoLevel
            )
        ]
        guard propertyStatuses.allSatisfy({ $0 == noErr }),
              VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            return "This Mac cannot prepare the selected source for 4K/60 H.264 encoding."
        }
        return nil
    }
}
