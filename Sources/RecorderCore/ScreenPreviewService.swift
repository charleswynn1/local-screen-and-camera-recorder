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
        let configuration = SCStreamConfiguration()
        configuration.width = Int(min(maximumSize.width, outputSize.width))
        configuration.height = Int(min(maximumSize.height, outputSize.height))
        configuration.showsCursor = showsCursor
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        if let sourceRect = target.sourceRectInPoints {
            configuration.sourceRect = sourceRect
        }
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }
}
