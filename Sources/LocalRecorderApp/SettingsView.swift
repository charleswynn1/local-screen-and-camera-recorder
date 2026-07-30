import RecorderCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Saving") {
                LabeledContent("Recording folder") {
                    HStack {
                        Text(model.folderURL?.path(percentEncoded: false) ?? "Not selected")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Choose…") {
                            Task { await model.chooseFolder() }
                        }
                    }
                }
            }

            Section("Default Quality") {
                Picker("Quality", selection: $model.configuration.quality) {
                    ForEach(QualityPreset.allCases) { preset in
                        VStack(alignment: .leading) {
                            Text(preset.title)
                            Text(preset.detail)
                        }
                        .tag(preset)
                        .disabled(
                            preset == .high
                                && model.highQualityIssue != nil
                        )
                    }
                }
                .pickerStyle(.radioGroup)
                if let issue = model.highQualityIssue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Keyboard Shortcuts") {
                LabeledContent("Start or stop") {
                    Text("⌃⌥R")
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Pause or resume") {
                    Text("⌃⌥P")
                        .font(.system(.body, design: .monospaced))
                }
                Text("Global shortcuts use macOS hot-key registration and do not require Accessibility access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Label("Recordings never leave this Mac.", systemImage: "lock.shield.fill")
                Text("Local Recorder contains no account system, analytics, cloud storage, or network client entitlement.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open Privacy & Security Settings") {
                    model.openPrivacySettings()
                }
            }

            Section("About") {
                LabeledContent("Application", value: "Local Recorder")
                LabeledContent("Version", value: "0.1.0")
                LabeledContent("Requirements", value: "Apple Silicon · macOS 15 or later")
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Settings")
    }
}
