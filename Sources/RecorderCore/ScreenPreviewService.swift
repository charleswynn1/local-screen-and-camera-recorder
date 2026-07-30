@preconcurrency import ScreenCaptureKit
import CoreGraphics
import Foundation

public enum ScreenPreviewService {
    public static func image(
        for target: ScreenCaptureTarget,
        maximumSize: CGSize = CGSize(width: 1_280, height: 800),
        showsCursor: Bool = true
    ) async throws -> CGImage {
        guard let filter = target.filter else {
            throw RecorderError.invalidConfiguration(
                "Select a live screen source before previewing."
            )
        }
        let outputSize = OutputGeometry.outputSize(
            sourceSize: target.pixelSize,
            preset: .compact
        )
        let croppedPreviewSize = CGSize(
            width: min(maximumSize.width, outputSize.width),
            height: min(maximumSize.height, outputSize.height)
        )
        let captureSize = target.captureOutputSize(
            for: croppedPreviewSize
        )
        let configuration = SCStreamConfiguration()
        configuration.width = Int(captureSize.width)
        configuration.height = Int(captureSize.height)
        configuration.showsCursor = showsCursor
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        if let sourceRect = target.sourceRectInPoints {
            configuration.sourceRect = sourceRect
        }
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        guard let crop = target.outputCrop else { return image }
        let imageSize = CGSize(width: image.width, height: image.height)
        let cropRect = crop
            .denormalized(in: imageSize)
            .integral
            .intersection(CGRect(origin: .zero, size: imageSize))
        guard cropRect.width >= 1,
              cropRect.height >= 1,
              let cropped = image.cropping(to: cropRect) else {
            throw RecorderError.captureFailed(
                "The window content preview could not be cropped."
            )
        }
        return cropped
    }
}
