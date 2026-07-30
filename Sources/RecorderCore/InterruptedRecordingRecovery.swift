@preconcurrency import AVFoundation
import CoreMedia
import Foundation

public struct RecoveryReport: Sendable {
    public let recovered: [URL]
    public let invalid: [URL]

    public init(recovered: [URL], invalid: [URL]) {
        self.recovered = recovered
        self.invalid = invalid
    }
}

public actor InterruptedRecordingRecovery {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func recover(in folder: URL) async -> RecoveryReport {
        guard let files = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return RecoveryReport(recovered: [], invalid: [])
        }
        let partials = files.filter {
            $0.lastPathComponent.hasPrefix(".Local Recorder ")
                && $0.lastPathComponent.hasSuffix(".part.mp4")
        }
        var recovered = [URL]()
        var invalid = [URL]()
        for partial in partials {
            guard await isPlayableRecording(at: partial) else {
                invalid.append(partial)
                continue
            }
            let destination = uniqueRecoveryURL(in: folder)
            do {
                try fileManager.moveItem(at: partial, to: destination)
                recovered.append(destination)
            } catch {
                invalid.append(partial)
            }
        }
        return RecoveryReport(recovered: recovered, invalid: invalid)
    }

    public func discard(_ files: [URL]) {
        for file in files {
            var resultingURL: NSURL?
            try? fileManager.trashItem(
                at: file,
                resultingItemURL: &resultingURL
            )
        }
    }

    private func uniqueRecoveryURL(in folder: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Local Recorder Recovered \(formatter.string(from: Date()))"
        var candidate = folder.appendingPathComponent(base).appendingPathExtension("mp4")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder
                .appendingPathComponent("\(base) \(suffix)")
                .appendingPathExtension("mp4")
            suffix += 1
        }
        return candidate
    }

    private func isPlayableRecording(at url: URL) async -> Bool {
        do {
            let asset = AVURLAsset(url: url)
            let videoTracks = try await asset.loadTracks(
                withMediaType: .video
            )
            guard videoTracks.count == 1 else { return false }
            let videoDescriptions = try await videoTracks[0].load(
                .formatDescriptions
            )
            guard videoDescriptions.contains(where: {
                CMFormatDescriptionGetMediaSubType($0)
                    == kCMVideoCodecType_H264
            }) else {
                return false
            }

            let audioTracks = try await asset.loadTracks(
                withMediaType: .audio
            )
            guard audioTracks.count <= 1 else { return false }
            if let audioTrack = audioTracks.first {
                let audioDescriptions = try await audioTrack.load(
                    .formatDescriptions
                )
                guard audioDescriptions.contains(where: {
                    CMFormatDescriptionGetMediaSubType($0)
                        == kAudioFormatMPEG4AAC
                }) else {
                    return false
                }
            }

            let duration = try await asset.load(.duration)
            return duration.isNumeric && duration > .zero
        } catch {
            return false
        }
    }
}
