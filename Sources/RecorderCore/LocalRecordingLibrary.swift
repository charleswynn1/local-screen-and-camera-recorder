@preconcurrency import AVFoundation
import Foundation

public protocol TrashMoving: Sendable {
    func moveToTrash(_ url: URL) throws
}

public final class SystemTrashMover:
    TrashMoving,
    @unchecked Sendable
{
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func moveToTrash(_ url: URL) throws {
        var resultingURL: NSURL?
        try fileManager.trashItem(
            at: url,
            resultingItemURL: &resultingURL
        )
    }
}

public actor LocalRecordingLibrary: RecordingLibrary {
    private let fileManager: FileManager
    private let trashMover: any TrashMoving

    public init(
        fileManager: FileManager = .default,
        trashMover: (any TrashMoving)? = nil
    ) {
        self.fileManager = fileManager
        self.trashMover = trashMover
            ?? SystemTrashMover(fileManager: fileManager)
    }

    public func recordings(in folder: URL) async throws -> [RecordingArtifact] {
        let urls = try fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var artifacts = [RecordingArtifact]()
        for url in urls where url.pathExtension.lowercased() == "mp4" {
            if let artifact = try? await artifact(for: url) {
                artifacts.append(artifact)
            }
        }
        return artifacts.sorted { $0.createdAt > $1.createdAt }
    }

    public func rename(
        _ artifact: RecordingArtifact,
        to requestedName: String
    ) async throws -> RecordingArtifact {
        let sanitized = requestedName
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            throw RecorderError.invalidConfiguration("Enter a non-empty recording name.")
        }
        let destination = artifact.url
            .deletingLastPathComponent()
            .appendingPathComponent(sanitized)
            .appendingPathExtension("mp4")
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw RecorderError.invalidConfiguration("A recording with that name already exists.")
        }
        try fileManager.moveItem(at: artifact.url, to: destination)
        return try await self.artifact(for: destination)
    }

    public func moveToTrash(_ artifact: RecordingArtifact) async throws {
        try trashMover.moveToTrash(artifact.url)
    }

    private func artifact(for url: URL) async throws -> RecordingArtifact {
        let values = try url.resourceValues(forKeys: [
            .creationDateKey,
            .contentModificationDateKey,
            .fileSizeKey
        ])
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return RecordingArtifact(
            url: url,
            createdAt: values.creationDate ?? values.contentModificationDate ?? .distantPast,
            duration: duration.isNumeric ? max(0, duration.seconds) : 0,
            fileSize: Int64(values.fileSize ?? 0)
        )
    }
}
