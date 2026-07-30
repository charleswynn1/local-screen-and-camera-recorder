import RecorderCore
import SwiftUI

struct RecordView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                modePicker
                    .disabled(model.snapshot.phase == .countingDown)
                sourceSection
                    .disabled(model.snapshot.phase == .countingDown)
                preview
                    .disabled(model.snapshot.phase == .countingDown)
                controls
                    .disabled(model.snapshot.phase == .countingDown)
                permissionAndFolderCards
                    .disabled(model.snapshot.phase == .countingDown)
                recordControls
            }
            .padding(28)
            .frame(maxWidth: 1_050)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand {
            if model.snapshot.phase == .countingDown {
                model.cancelCountdown()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New Recording")
                .font(.largeTitle.bold())
            Text("Choose what to capture, check the preview, then press Record.")
                .foregroundStyle(.secondary)
        }
    }

    private var modePicker: some View {
        HStack(spacing: 12) {
            ForEach(CaptureMode.allCases) { mode in
                Button {
                    model.selectMode(mode)
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: mode.systemImage)
                            .font(.title2)
                        Text(mode.title)
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(
                        model.configuration.mode == mode
                            ? Color.accentColor.opacity(0.16)
                            : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                model.configuration.mode == mode
                                    ? Color.accentColor
                                    : Color.clear,
                                lineWidth: 2
                            )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(
                    model.configuration.mode == mode ? .isSelected : []
                )
            }
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        if model.configuration.mode.needsScreen {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Screen Source")
                HStack {
                    ForEach(ScreenSelectionKind.allCases) { kind in
                        Button {
                            Task { await model.chooseScreen(kind) }
                        } label: {
                            Label(kind.title, systemImage: kind.systemImage)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                if let selection = model.configuration.screenSelection {
                    Label(selection.label, systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                } else {
                    Text("No screen source selected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Preview")
                Spacer()
                if model.configuration.mode == .combined {
                    Picker("Camera size", selection: $model.configuration.overlay.size) {
                        ForEach(OverlaySize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            }
            PreviewCanvas(model: model)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.primary.opacity(0.12))
                }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Recording Options")
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    if model.configuration.mode.needsCamera {
                        devicePicker(
                            title: "Camera",
                            devices: model.cameras,
                            selection: Binding(
                                get: { model.configuration.cameraDeviceID },
                                set: { model.setCameraDevice($0) }
                            )
                        )
                    }
                    if model.configuration.capturesMicrophone {
                        devicePicker(
                            title: "Microphone",
                            devices: model.microphones,
                            selection: Binding(
                                get: { model.configuration.microphoneDeviceID },
                                set: { model.setMicrophoneDevice($0) }
                            )
                        )
                    }
                    Picker("Quality", selection: $model.configuration.quality) {
                        ForEach(QualityPreset.allCases) { preset in
                            Text("\(preset.title) — \(preset.detail)")
                                .tag(preset)
                                .disabled(
                                    preset == .high
                                        && model.highQualityIssue != nil
                                )
                        }
                    }
                    .frame(maxWidth: 330)
                    .accessibilityIdentifier("quality-picker")
                    if let issue = model.highQualityIssue {
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 330, alignment: .leading)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    if model.configuration.mode.needsScreen {
                        Toggle(
                            isOn: Binding(
                                get: { model.configuration.capturesSystemAudio },
                                set: { model.setCapturesSystemAudio($0) }
                            )
                        ) {
                            AudioToggleLabel(
                                title: "System audio",
                                level: model.systemAudioLevel
                            )
                        }
                    }
                    Toggle(
                        isOn: Binding(
                            get: { model.configuration.capturesMicrophone },
                            set: { model.setCapturesMicrophone($0) }
                        )
                    ) {
                        AudioToggleLabel(
                            title: "Microphone",
                            level: model.microphoneLevel
                        )
                    }
                    if model.configuration.mode.needsScreen {
                        Toggle("Show cursor", isOn: $model.configuration.showsCursor)
                        Toggle(
                            "Highlight clicks",
                            isOn: $model.configuration.showsMouseClicks
                        )
                    }
                }
                .toggleStyle(.switch)
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var permissionAndFolderCards: some View {
        VStack(spacing: 8) {
            if model.configuration.mode.needsScreen {
                PermissionRow(
                    kind: .screen,
                    status: model.permissions[.screen] ?? .notDetermined
                ) {
                    Task { await model.requestPermission(.screen) }
                }
            }
            if model.configuration.mode.needsCamera {
                PermissionRow(
                    kind: .camera,
                    status: model.permissions[.camera] ?? .notDetermined
                ) {
                    Task { await model.requestPermission(.camera) }
                }
            }
            if model.configuration.capturesMicrophone {
                PermissionRow(
                    kind: .microphone,
                    status: model.permissions[.microphone] ?? .notDetermined
                ) {
                    Task { await model.requestPermission(.microphone) }
                }
            }
            HStack {
                Image(systemName: model.folderURL == nil ? "folder.badge.questionmark" : "folder.fill")
                    .foregroundStyle(model.folderURL == nil ? .orange : .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording folder")
                        .font(.callout.weight(.medium))
                    Text(model.folderURL?.path(percentEncoded: false) ?? "Choose where recordings are saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(model.folderURL == nil ? "Choose…" : "Change…") {
                    Task { await model.chooseFolder() }
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private var recordControls: some View {
        if model.snapshot.phase == .countingDown {
            HStack {
                Text("Recording begins in \(model.snapshot.countdown ?? 0)…")
                    .font(.title2.bold())
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.cancelCountdown()
                }
            }
            .padding()
        } else {
            Button {
                model.startRecording()
            } label: {
                Label("Start Recording", systemImage: "record.circle.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!model.canRecord)
            .controlSize(.large)
            .help("Control–Option–R")
        }
    }

    private func devicePicker(
        title: String,
        devices: [CaptureDeviceDescriptor],
        selection: Binding<String?>
    ) -> some View {
        Picker(title, selection: selection) {
            if devices.isEmpty {
                Text("No devices found").tag(String?.none)
            }
            ForEach(devices) { device in
                Text(device.isSystemPreferred ? "\(device.name) — Preferred" : device.name)
                    .tag(Optional(device.id))
            }
        }
        .frame(maxWidth: 330)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
    }
}

private struct AudioToggleLabel: View {
    let title: String
    let level: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(meterColor)
                        .frame(
                            width: max(
                                2,
                                geometry.size.width
                                    * min(1, max(0, level))
                            )
                        )
                }
            }
            .frame(width: 64, height: 6)
            .accessibilityLabel("\(title) input level")
            .accessibilityValue("\(Int(level * 100)) percent")
        }
    }

    private var meterColor: Color {
        if level > 0.88 { return .red }
        if level > 0.7 { return .orange }
        return .green
    }
}

private struct PreviewCanvas: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if model.configuration.mode.needsScreen {
                    if let preview = model.screenPreview {
                        Image(nsImage: preview)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        PreviewPlaceholder(
                            icon: "rectangle.dashed",
                            text: "Choose a screen source"
                        )
                    }
                }

                if model.configuration.mode == .camera {
                    CameraPreviewView(session: model.cameraPreview.session)
                } else if model.configuration.mode == .combined {
                    let width = geometry.size.width
                        * model.configuration.overlay.size.widthFraction
                    let height = width * 9 / 16
                    CameraPreviewView(session: model.cameraPreview.session)
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: max(8, height * 0.08)))
                        .overlay {
                            RoundedRectangle(cornerRadius: max(8, height * 0.08))
                                .stroke(.white.opacity(0.8), lineWidth: 2)
                        }
                        .shadow(radius: 8, y: 4)
                        .position(
                            position(
                                for: model.configuration.overlay.corner,
                                overlaySize: CGSize(width: width, height: height),
                                canvas: geometry.size
                            )
                        )
                        .gesture(
                            DragGesture(coordinateSpace: .local)
                                .onEnded { value in
                                    let horizontalLeading = value.location.x < geometry.size.width / 2
                                    let verticalTop = value.location.y < geometry.size.height / 2
                                    let corner: OverlayCorner
                                    switch (verticalTop, horizontalLeading) {
                                    case (true, true): corner = .topLeading
                                    case (true, false): corner = .topTrailing
                                    case (false, true): corner = .bottomLeading
                                    case (false, false): corner = .bottomTrailing
                                    }
                                    model.setOverlayCorner(corner)
                                }
                        )
                }

                if model.snapshot.phase == .countingDown {
                    Color.black.opacity(0.52)
                    Text("\(model.snapshot.countdown ?? 0)")
                        .font(.system(size: 96, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 12)
                }
            }
        }
    }

    private func position(
        for corner: OverlayCorner,
        overlaySize: CGSize,
        canvas: CGSize
    ) -> CGPoint {
        let margin = max(12, min(canvas.width, canvas.height) * 0.025)
        let leading = margin + overlaySize.width / 2
        let trailing = canvas.width - margin - overlaySize.width / 2
        let top = margin + overlaySize.height / 2
        let bottom = canvas.height - margin - overlaySize.height / 2
        switch corner {
        case .topLeading: return CGPoint(x: leading, y: top)
        case .topTrailing: return CGPoint(x: trailing, y: top)
        case .bottomLeading: return CGPoint(x: leading, y: bottom)
        case .bottomTrailing: return CGPoint(x: trailing, y: bottom)
        }
    }
}

private struct PreviewPlaceholder: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
            Text(text)
        }
        .foregroundStyle(.white.opacity(0.7))
    }
}

private struct PermissionRow: View {
    let kind: PermissionKind
    let status: PermissionStatus
    let request: () -> Void

    var body: some View {
        HStack {
            Image(systemName: status == .authorized ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .foregroundStyle(status == .authorized ? .green : .orange)
            Text("\(kind.title) access")
                .font(.callout.weight(.medium))
            Spacer()
            if status == .authorized {
                Text("Ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Grant Access", action: request)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}
