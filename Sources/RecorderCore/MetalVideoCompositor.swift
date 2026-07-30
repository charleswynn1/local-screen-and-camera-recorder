@preconcurrency import CoreImage
import CoreVideo
import Foundation
import Metal

public final class MetalVideoCompositor: VideoCompositor, @unchecked Sendable {
    private let context: CIContext
    private let colorSpace: CGColorSpace

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RecorderError.captureFailed("Metal is unavailable on this Mac.")
        }
        guard let colorSpace = CGColorSpace(
            name: CGColorSpace.itur_709
        ) else {
            throw RecorderError.captureFailed(
                "The Rec. 709 color space is unavailable."
            )
        }
        self.colorSpace = colorSpace
        context = CIContext(mtlDevice: device, options: [
            .cacheIntermediates: false,
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace
        ])
    }

    public func render(
        screen: CVPixelBuffer?,
        camera: CVPixelBuffer?,
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
            throw RecorderError.writerFailed("Could not allocate a video frame (\(status)).")
        }

        let canvas = CGRect(origin: .zero, size: outputSize)
        let black = CIImage(color: .black).cropped(to: canvas)
        let composed: CIImage
        switch mode {
        case .screen:
            guard let screen else { throw RecorderError.noVideoFrames }
            composed = fit(CIImage(cvPixelBuffer: screen), into: canvas, background: black)
        case .camera:
            guard let camera else { throw RecorderError.noVideoFrames }
            composed = fill(CIImage(cvPixelBuffer: camera), into: canvas)
        case .combined:
            guard let screen else { throw RecorderError.noVideoFrames }
            let base = fit(CIImage(cvPixelBuffer: screen), into: canvas, background: black)
            guard let camera else {
                composed = base
                break
            }
            let overlayFrame = overlay.frame(in: outputSize)
            composed = try addCamera(
                CIImage(cvPixelBuffer: camera),
                frame: overlayFrame,
                to: base,
                canvas: canvas
            )
        }

        context.render(
            composed.cropped(to: canvas),
            to: output,
            bounds: canvas,
            colorSpace: colorSpace
        )
        return output
    }

    private func fit(_ image: CIImage, into destination: CGRect, background: CIImage) -> CIImage {
        let transformed = image.transformed(
            by: OutputGeometry.aspectFitTransform(from: image.extent, to: destination)
        )
        return transformed.composited(over: background)
    }

    private func fill(_ image: CIImage, into destination: CGRect) -> CIImage {
        image.transformed(
            by: OutputGeometry.aspectFillTransform(from: image.extent, to: destination)
        ).cropped(to: destination)
    }

    private func addCamera(
        _ camera: CIImage,
        frame: CGRect,
        to background: CIImage,
        canvas: CGRect
    ) throws -> CIImage {
        let radius = max(8, frame.height * 0.08)
        guard let mask = CIFilter(
            name: "CIRoundedRectangleGenerator",
            parameters: [
                "inputExtent": CIVector(cgRect: frame),
                "inputRadius": radius,
                "inputColor": CIColor.white
            ]
        )?.outputImage?.cropped(to: canvas) else {
            throw RecorderError.captureFailed(
                "The camera overlay mask could not be created."
            )
        }

        let shadowMask = mask
            .transformed(by: CGAffineTransform(translationX: 0, y: -max(3, frame.height * 0.02)))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(4, frame.height * 0.025)])
            .cropped(to: canvas)
        let shadowColor = CIImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45)
        ).cropped(to: canvas)
        let withShadow = shadowColor.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: background,
                kCIInputMaskImageKey: shadowMask
            ]
        )

        let cameraImage = fill(camera, into: frame)
        return cameraImage.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: withShadow,
                kCIInputMaskImageKey: mask
            ]
        )
    }
}
