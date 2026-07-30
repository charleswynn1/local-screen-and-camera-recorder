@preconcurrency import AVFoundation
import AppKit
import AVKit
import RecorderCore
import SwiftUI

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @State private var renameText = ""
    @State private var isRenaming = false
    @State private var trashCandidate: RecordingArtifact?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recordings")
                        .font(.title2.bold())
                    Spacer()
                    Button {
                        Task { await model.refreshLibrary() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                }
                .padding()

                if model.recordings.isEmpty {
                    ContentUnavailableView(
                        "No Recordings",
                        systemImage: "film.stack",
                        description: Text("Completed MP4 files in your recording folder appear here.")
                    )
                } else {
                    List(model.recordings, selection: $model.selectedRecording) { artifact in
                        RecordingRow(artifact: artifact)
                            .tag(artifact)
                    }
                }
            }
            .frame(minWidth: 280, idealWidth: 330)

            detail
                .frame(minWidth: 430)
        }
        .alert("Rename Recording", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let artifact = model.selectedRecording else { return }
                Task { await model.rename(artifact, to: renameText) }
            }
        }
        .alert(
            "Move Recording to Trash?",
            isPresented: Binding(
                get: { trashCandidate != nil },
                set: { if !$0 { trashCandidate = nil } }
            ),
            presenting: trashCandidate
        ) { artifact in
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                Task { await model.moveToTrash(artifact) }
            }
        } message: { artifact in
            Text("“\(artifact.url.deletingPathExtension().lastPathComponent)” can be recovered from Trash.")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let artifact = model.selectedRecording {
            VStack(alignment: .leading, spacing: 16) {
                RecordingPlayerView(url: artifact.url)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Text(artifact.url.deletingPathExtension().lastPathComponent)
                    .font(.title2.bold())
                    .lineLimit(2)
                Text("\(artifact.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(duration(artifact.duration)) · \(ByteCountFormatter.string(fromByteCount: artifact.fileSize, countStyle: .file))")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Rename") {
                        renameText = artifact.url.deletingPathExtension().lastPathComponent
                        isRenaming = true
                    }
                    Button("Show in Finder") {
                        model.reveal(artifact)
                    }
                    ShareLink(item: artifact.url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Spacer()
                    Button("Move to Trash", role: .destructive) {
                        trashCandidate = artifact
                    }
                }
                Spacer()
            }
            .padding(24)
        } else {
            ContentUnavailableView(
                "Select a Recording",
                systemImage: "play.rectangle",
                description: Text("Choose a recording to preview or manage it.")
            )
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(
            .time(pattern: .hourMinuteSecond(padHourToLength: seconds >= 3_600 ? 2 : 0))
        )
    }
}

private struct RecordingPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        let currentURL = (view.player?.currentItem?.asset as? AVURLAsset)?.url
        if currentURL != url {
            view.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(
        _ view: AVPlayerView,
        coordinator: Void
    ) {
        view.player?.pause()
        view.player = nil
    }
}

private struct RecordingRow: View {
    let artifact: RecordingArtifact
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.black
                        Image(systemName: "play.fill")
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .frame(width: 72, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(artifact.url.deletingPathExtension().lastPathComponent)
                    .lineLimit(1)
                Text(artifact.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .task(id: artifact.url) {
            thumbnail = await RecordingThumbnailCache.shared.image(for: artifact.url)
        }
    }
}

@MainActor
private final class RecordingThumbnailCache {
    static let shared = RecordingThumbnailCache()

    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 120
        cache.totalCostLimit = 32 * 1_024 * 1_024
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        guard let result = try? await generator.image(
            at: CMTime(seconds: 0.25, preferredTimescale: 600)
        ) else {
            return nil
        }
        let image = NSImage(cgImage: result.image, size: .zero)
        cache.setObject(
            image,
            forKey: url as NSURL,
            cost: max(1, result.image.bytesPerRow * result.image.height)
        )
        return image
    }
}
