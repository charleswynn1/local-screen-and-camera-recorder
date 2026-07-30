import RecorderCore
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $model.selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                privacyBadge
            }
        } detail: {
            Group {
                switch model.selectedSection {
                case .record:
                    RecordView(model: model)
                case .library:
                    LibraryView(model: model)
                case .settings:
                    SettingsView(model: model)
                }
            }
            .frame(minWidth: 760, minHeight: 590)
        }
        .alert(
            "Local Recorder",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
            Button("Open System Settings") { model.openPrivacySettings() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            "Interrupted Recording",
            isPresented: Binding(
                get: { !model.invalidRecoveryFiles.isEmpty },
                set: { _ in }
            )
        ) {
            Button("Move Remnants to Trash", role: .destructive) {
                Task { await model.discardInvalidRecoveryFiles() }
            }
            Button("Keep Files", role: .cancel) {
                model.invalidRecoveryFiles = []
            }
        } message: {
            Text("An interrupted recording could not be repaired. Its hidden staging file can be kept for manual recovery or removed.")
        }
        .overlay(alignment: .top) {
            if let notice = model.noticeMessage {
                NoticeBanner(text: notice) {
                    model.noticeMessage = nil
                }
                .padding()
            }
        }
    }

    private var privacyBadge: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.shield")
            Text("Local-only · No uploads")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding()
    }
}

struct NoticeBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            Text(text)
                .font(.callout)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8, y: 3)
        .frame(maxWidth: 600)
    }
}
