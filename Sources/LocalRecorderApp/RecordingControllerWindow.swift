import AppKit
import SwiftUI

@MainActor
final class RecordingControllerWindowManager {
    private var panel: NSPanel?
    private weak var mainWindow: NSWindow?

    func show(model: AppModel) {
        if let panel {
            panel.contentView = NSHostingView(rootView: RecordingControllerView(model: model))
            return
        }
        mainWindow = NSApp.windows.first {
            $0.isVisible && !($0 is NSPanel) && $0.level == .normal
        }
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecordingControllerView(model: model))
        if let screen = mainWindow?.screen ?? NSScreen.main {
            panel.setFrameOrigin(
                CGPoint(
                    x: screen.visibleFrame.maxX - panel.frame.width - 24,
                    y: screen.visibleFrame.maxY - panel.frame.height - 24
                )
            )
        }
        panel.orderFrontRegardless()
        mainWindow?.orderOut(nil)
        self.panel = panel
    }

    func closeAndRestore() {
        panel?.orderOut(nil)
        panel = nil
        restoreMainWindow()
    }

    func restoreMainWindow() {
        let window = mainWindow ?? NSApp.windows.first {
            $0.canBecomeMain && !($0 is NSPanel)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct RecordingControllerView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.snapshot.phase == .paused ? Color.orange : Color.red)
                .frame(width: 12, height: 12)
            Text(model.snapshot.phase == .finalizing ? "Saving…" : model.elapsedText)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .frame(minWidth: 78, alignment: .leading)
            Spacer()
            if model.snapshot.phase != .finalizing {
                Button {
                    model.togglePause()
                } label: {
                    Image(systemName: model.snapshot.phase == .paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .help("Control–Option–P")
                Button {
                    model.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help("Control–Option–R")
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 360, height: 72)
        .background(.ultraThickMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.16))
        }
    }
}
