@preconcurrency import AppKit
import RecorderCore
import SwiftUI

@main
@MainActor
struct LocalRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Local Recorder") {
            RootView(model: model)
                .frame(minWidth: 960, minHeight: 640)
                .task {
                    appDelegate.install(model: model)
                    await model.bootstrap()
                }
        }
        .defaultSize(width: 1_100, height: 760)
        .commands {
            CommandMenu("Recording") {
                Button("Start or Stop Recording") {
                    model.startOrStopFromHotKey()
                }
                .keyboardShortcut("r", modifiers: [.control, .option])

                Button(model.snapshot.phase == .paused ? "Resume Recording" : "Pause Recording") {
                    model.togglePause()
                }
                .keyboardShortcut("p", modifiers: [.control, .option])
                .disabled(![.recording, .paused].contains(model.snapshot.phase))
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AppModel?
    private var hotKeys: GlobalHotKeyManager?

    func install(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        hotKeys = GlobalHotKeyManager { [weak model] action in
            guard let model else { return }
            switch action {
            case .record:
                model.startOrStopFromHotKey()
            case .pause:
                model.togglePause()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.needsTerminationDelay else {
            return .terminateNow
        }
        if model.snapshot.phase == .finalizing {
            let alert = NSAlert()
            alert.messageText = "Local Recorder is finishing the MP4"
            alert.informativeText = "Wait for finalization to complete before quitting so the recording remains playable."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Keep Finalizing")
            alert.runModal()
            return .terminateCancel
        }

        let alert = NSAlert()
        alert.messageText = "Finish the recording and quit?"
        alert.informativeText = "Local Recorder will stop capture and preserve the playable portion before quitting."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Finish and Quit")
        alert.addButton(withTitle: "Keep Recording")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }
        Task {
            await model.finishBeforeTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
