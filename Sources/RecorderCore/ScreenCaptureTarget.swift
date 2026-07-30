@preconcurrency import ScreenCaptureKit
import CoreGraphics
import Foundation

public final class ScreenCaptureTarget: @unchecked Sendable {
    public let filter: SCContentFilter?
    public let selection: ScreenSelection
    public let sourceRectInPoints: CGRect?
    public let pointPixelScale: CGFloat
    public let contentPointSize: CGSize

    public init(
        filter: SCContentFilter,
        selection: ScreenSelection,
        sourceRectInPoints: CGRect? = nil
    ) {
        self.filter = filter
        self.selection = selection
        self.sourceRectInPoints = sourceRectInPoints
        pointPixelScale = max(1, CGFloat(filter.pointPixelScale))
        contentPointSize = filter.contentRect.size
    }

    /// Creates a geometry-only target for deterministic validation and
    /// protocol-fake tests. Platform capture services reject it until a live
    /// ScreenCaptureKit filter has been selected.
    public init(
        selection: ScreenSelection,
        contentPointSize: CGSize,
        pointPixelScale: CGFloat,
        sourceRectInPoints: CGRect? = nil
    ) {
        filter = nil
        self.selection = selection
        self.sourceRectInPoints = sourceRectInPoints
        self.pointPixelScale = max(1, pointPixelScale)
        self.contentPointSize = contentPointSize
    }

    public var pointSize: CGSize {
        sourceRectInPoints?.size ?? contentPointSize
    }

    public var pixelSize: CGSize {
        CGSize(
            width: pointSize.width * pointPixelScale,
            height: pointSize.height * pointPixelScale
        )
    }

    public func applying(region: NormalizedRect, displayID: UInt32?, displayName: String) -> ScreenCaptureTarget {
        let localRect = region.denormalized(in: contentPointSize)
        guard let filter else {
            return ScreenCaptureTarget(
                selection: .region(
                    displayID: displayID,
                    displayName: displayName,
                    rect: region
                ),
                contentPointSize: contentPointSize,
                pointPixelScale: pointPixelScale,
                sourceRectInPoints: localRect
            )
        }
        return ScreenCaptureTarget(
            filter: filter,
            selection: .region(displayID: displayID, displayName: displayName, rect: region),
            sourceRectInPoints: localRect
        )
    }
}

public enum ScreenDisplayTargetResolver {
    public static func resolve(
        displayID: UInt32,
        displayName: String,
        excludingBundleID: String?
    ) async throws -> ScreenCaptureTarget {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first(where: {
                $0.displayID == displayID
            }) else {
                throw RecorderError.captureFailed(
                    "The selected display is no longer available."
                )
            }

            let excludedApplications: [SCRunningApplication]
            let excludedWindows: [SCWindow]
            if let excludingBundleID {
                excludedApplications = content.applications.filter {
                    $0.bundleIdentifier == excludingBundleID
                }
                excludedWindows = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier
                        == excludingBundleID
                }
            } else {
                excludedApplications = []
                excludedWindows = []
            }
            let filter: SCContentFilter
            if excludedApplications.isEmpty {
                filter = SCContentFilter(
                    display: display,
                    excludingWindows: excludedWindows
                )
            } else {
                filter = SCContentFilter(
                    display: display,
                    excludingApplications: excludedApplications,
                    exceptingWindows: []
                )
            }

            return ScreenCaptureTarget(
                filter: filter,
                selection: .display(id: displayID, name: displayName)
            )
        } catch let error as RecorderError {
            throw error
        } catch {
            throw RecorderError.captureFailed(
                "Could not prepare the selected display: \(error.localizedDescription)"
            )
        }
    }
}
