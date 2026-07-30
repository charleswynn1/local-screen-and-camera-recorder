import AppKit
import SwiftUI

@MainActor
final class RecordingControllerWindowManager {
    private var panel: NSPanel?
    private weak var mainWindow: NSWindow?

    func show(model: AppModel) {
        let contentSize = RecordingControllerLayout.size(for: model)
        if let panel {
            panel.contentView = NSHostingView(rootView: RecordingControllerView(model: model))
            let topRight = CGPoint(
                x: panel.frame.maxX,
                y: panel.frame.maxY
            )
            panel.setFrame(
                constrainedFrame(
                    CGRect(
                        x: topRight.x - contentSize.width,
                        y: topRight.y - contentSize.height,
                        width: contentSize.width,
                        height: contentSize.height
                    ),
                    for: panel
                ),
                display: true
            )
            panel.orderFrontRegardless()
            return
        }
        mainWindow = NSApp.windows.first {
            $0.isVisible && !($0 is NSPanel) && $0.level == .normal
        }
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
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

    private func constrainedFrame(
        _ proposedFrame: CGRect,
        for panel: NSPanel
    ) -> CGRect {
        guard let screen = panel.screen
            ?? mainWindow?.screen
            ?? NSScreen.main else {
            return proposedFrame
        }
        return panel.constrainFrameRect(proposedFrame, to: screen)
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

private enum RecordingControllerLayout {
    static let compactSize = CGSize(width: 360, height: 72)
    static let cameraSize = CGSize(width: 528, height: 368)

    @MainActor
    static func size(for model: AppModel) -> CGSize {
        model.configuration.mode == .camera
            && model.isRecordingCameraPreviewVisible
            ? cameraSize
            : compactSize
    }
}

private struct RecordingControllerView: View {
    @ObservedObject var model: AppModel

    private var showsCameraPreview: Bool {
        model.configuration.mode == .camera
            && model.isRecordingCameraPreviewVisible
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsCameraPreview {
                cameraPreview
            }
            controls
        }
        .frame(
            width: RecordingControllerLayout.size(for: model).width,
            height: RecordingControllerLayout.size(for: model).height
        )
        .background(
            .ultraThickMaterial,
            in: RoundedRectangle(
                cornerRadius: showsCameraPreview ? 20 : 36,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: showsCameraPreview ? 20 : 36,
                style: .continuous
            )
            .stroke(Color.white.opacity(0.16))
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: showsCameraPreview ? 20 : 36,
                style: .continuous
            )
        )
    }

    private var cameraPreview: some View {
        ZStack {
            Color.black
            if let preview = model.recordingCameraPreview {
                Image(nsImage: preview)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
                    .scaleEffect(x: -1, y: 1)
                    .clipped()
                    .accessibilityHidden(true)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Starting camera…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if model.snapshot.phase == .paused {
                Label("Paused", systemImage: "pause.fill")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThickMaterial, in: Capsule())
            }
        }
        .frame(width: 512, height: 288)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live Camera Preview")
        .accessibilityIdentifier("recording-camera-preview")
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.snapshot.phase == .paused ? Color.orange : Color.red)
                .frame(width: 12, height: 12)
            Text(model.snapshot.phase == .finalizing ? "Saving…" : model.elapsedText)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .frame(minWidth: 78, alignment: .leading)
            Spacer()
            if model.snapshot.phase != .finalizing {
                if model.configuration.mode == .camera {
                    Button {
                        model.toggleRecordingCameraPreview()
                    } label: {
                        Image(
                            systemName: showsCameraPreview
                                ? "rectangle.compress.vertical"
                                : "video.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(
                        showsCameraPreview
                            ? "Hide Camera Preview"
                            : "Show Camera Preview"
                    )
                    .help(
                        showsCameraPreview
                            ? "Hide the camera preview. Recording continues."
                            : "Show the live camera preview."
                    )
                }
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
        .frame(height: 72)
    }
}
