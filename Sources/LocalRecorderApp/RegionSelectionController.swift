import AppKit
import RecorderCore

@MainActor
final class RegionSelectionController {
    private var window: RegionSelectionWindow?
    private var continuation: CheckedContinuation<NormalizedRect, Error>?

    func selectRegion(for target: ScreenCaptureTarget) async throws -> NormalizedRect {
        guard continuation == nil else {
            throw RecorderError.captureFailed("A region selector is already open.")
        }
        let screen = matchingScreen(for: target) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else {
            throw RecorderError.captureFailed("No display is available for region selection.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let selectionView = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            selectionView.onComplete = { [weak self] rect in
                guard let self else { return }
                let normalized = NormalizedRect.from(
                    displayLocalAppKitRect: rect,
                    displaySize: screen.frame.size
                )
                finish(.success(normalized))
            }
            selectionView.onCancel = { [weak self] in
                self?.finish(.failure(RecorderError.cancelled))
            }
            let window = RegionSelectionWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = selectionView
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(selectionView)
            NSApp.activate(ignoringOtherApps: true)
            self.window = window
        }
    }

    private func matchingScreen(for target: ScreenCaptureTarget) -> NSScreen? {
        let selectedDisplayID: UInt32?
        switch target.selection {
        case let .display(id, _):
            selectedDisplayID = id
        case let .region(id, _, _):
            selectedDisplayID = id
        case .window:
            selectedDisplayID = nil
        }
        if let selectedDisplayID,
           let exact = NSScreen.screens.first(where: {
               (
                   $0.deviceDescription[
                       NSDeviceDescriptionKey("NSScreenNumber")
                   ] as? NSNumber
               )?.uint32Value == selectedDisplayID
           }) {
            return exact
        }
        guard target.filter != nil else { return NSScreen.main }
        return NSScreen.screens.min { lhs, rhs in
            score(lhs, target: target) < score(rhs, target: target)
        }
    }

    private func score(_ screen: NSScreen, target: ScreenCaptureTarget) -> CGFloat {
        guard let filter = target.filter else { return .greatestFiniteMagnitude }
        return abs(screen.frame.width - filter.contentRect.width)
            + abs(screen.frame.height - filter.contentRect.height)
            + abs(screen.frame.minX - filter.contentRect.minX)
            + abs(screen.frame.minY - filter.contentRect.minY)
            + abs(screen.backingScaleFactor - target.pointPixelScale) * 100
    }

    private func finish(_ result: Result<NormalizedRect, Error>) {
        window?.orderOut(nil)
        window = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}

final class RegionSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class RegionSelectionView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var anchor: CGPoint?
    private var selection = CGRect.zero

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        ).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard selection.width >= 64, selection.height >= 64 else {
            NSSound.beep()
            return
        }
        onComplete?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.42).setFill()
        bounds.fill()
        if !selection.isEmpty {
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            NSColor.systemRed.setStroke()
            let path = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1))
            path.lineWidth = 3
            path.stroke()
            drawSizeLabel()
        }
        drawInstruction()
    }

    private func drawInstruction() {
        let text = "Drag to select a region · Esc to cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let rect = CGRect(
            x: bounds.midX - size.width / 2 - 18,
            y: bounds.maxY - size.height - 42,
            width: size.width + 36,
            height: size.height + 16
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        text.draw(
            at: CGPoint(x: rect.minX + 18, y: rect.minY + 8),
            withAttributes: attributes
        )
    }

    private func drawSizeLabel() {
        let text = "\(Int(selection.width)) × \(Int(selection.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let rect = CGRect(
            x: selection.midX - size.width / 2 - 8,
            y: max(selection.minY - size.height - 18, 8),
            width: size.width + 16,
            height: size.height + 8
        )
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        text.draw(
            at: CGPoint(x: rect.minX + 8, y: rect.minY + 4),
            withAttributes: attributes
        )
    }
}
