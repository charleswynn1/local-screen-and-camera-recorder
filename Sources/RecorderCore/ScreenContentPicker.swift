@preconcurrency import ScreenCaptureKit
import AppKit
import Foundation

@MainActor
public final class ScreenContentPicker: NSObject, @preconcurrency SCContentSharingPickerObserver {
    private var continuation: CheckedContinuation<ScreenCaptureTarget, Error>?
    private var requestedKind: ScreenSelectionKind = .display
    private let picker = SCContentSharingPicker.shared

    public override init() {
        super.init()
        picker.add(self)
    }

    deinit {
        picker.remove(self)
    }

    public func pick(kind: ScreenSelectionKind, excludingBundleID: String?) async throws -> ScreenCaptureTarget {
        guard continuation == nil else {
            throw RecorderError.captureFailed("A content picker is already open.")
        }

        requestedKind = kind
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = kind == .window ? [.singleWindow] : [.singleDisplay]
        configuration.allowsChangingSelectedContent = false
        if let excludingBundleID {
            configuration.excludedBundleIDs = [excludingBundleID]
        }
        picker.configuration = configuration
        picker.isActive = true

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            picker.present(using: kind == .window ? .window : .display)
        }
    }

    public func cancelPending() {
        finish(.failure(RecorderError.cancelled))
    }

    public func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        finish(.failure(RecorderError.cancelled))
    }

    public func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        let selection: ScreenSelection
        switch requestedKind {
        case .window:
            if #available(macOS 15.2, *),
               let window = filter.includedWindows.first {
                let title = window.title?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                let resolvedTitle: String
                if let title, !title.isEmpty {
                    resolvedTitle = title
                } else {
                    resolvedTitle =
                        window.owningApplication?.applicationName
                        ?? "Selected Window"
                }
                selection = .window(
                    id: window.windowID,
                    title: resolvedTitle
                )
            } else {
                selection = .window(
                    id: nil,
                    title: "Selected Window"
                )
            }
        case .display, .region:
            let selectedDisplay: SCDisplay?
            if #available(macOS 15.2, *) {
                selectedDisplay = filter.includedDisplays.first
            } else {
                selectedDisplay = nil
            }
            let screen = selectedDisplay.flatMap {
                matchingScreen(displayID: $0.displayID)
            } ?? matchingScreen(for: filter)
            let screenDisplayID = (
                screen?.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber
            )?.uint32Value
            selection = .display(
                id: selectedDisplay?.displayID ?? screenDisplayID,
                name: screen?.localizedName ?? "Selected Display"
            )
        }
        finish(
            .success(
                ScreenCaptureTarget(
                    filter: filter,
                    selection: selection
                )
            )
        )
    }

    private func matchingScreen(for filter: SCContentFilter) -> NSScreen? {
        NSScreen.screens.min { lhs, rhs in
            score(lhs, filter: filter) < score(rhs, filter: filter)
        }
    }

    private func matchingScreen(
        displayID: CGDirectDisplayID
    ) -> NSScreen? {
        NSScreen.screens.first {
            (
                $0.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber
            )?.uint32Value == displayID
        }
    }

    private func score(_ screen: NSScreen, filter: SCContentFilter) -> CGFloat {
        abs(screen.frame.width - filter.contentRect.width)
            + abs(screen.frame.height - filter.contentRect.height)
            + abs(screen.frame.minX - filter.contentRect.minX)
            + abs(screen.frame.minY - filter.contentRect.minY)
            + abs(screen.backingScaleFactor - CGFloat(filter.pointPixelScale)) * 100
    }

    public func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<ScreenCaptureTarget, Error>) {
        let continuation = self.continuation
        self.continuation = nil
        picker.isActive = false
        continuation?.resume(with: result)
    }
}
