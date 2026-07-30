import Foundation

public struct SecurityScopedBookmarkResolution: Sendable {
    public let url: URL
    public let isStale: Bool

    public init(url: URL, isStale: Bool) {
        self.url = url
        self.isStale = isStale
    }
}

public protocol SecurityScopedBookmarkCoding: Sendable {
    func bookmark(for url: URL) throws -> Data
    func resolve(_ bookmark: Data) throws -> SecurityScopedBookmarkResolution
}

public enum RecordingFolderStoreError:
    LocalizedError,
    Equatable,
    Sendable
{
    case staleBookmark

    public var errorDescription: String? {
        switch self {
        case .staleBookmark:
            "The saved recording folder permission is stale."
        }
    }
}

public struct SystemSecurityScopedBookmarkCoder: SecurityScopedBookmarkCoding {
    public init() {}

    public func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public func resolve(
        _ bookmark: Data
    ) throws -> SecurityScopedBookmarkResolution {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return SecurityScopedBookmarkResolution(url: url, isStale: stale)
    }
}

public final class ScopedFolderAccess: @unchecked Sendable {
    public let url: URL
    private let isAccessing: Bool

    public init(url: URL) {
        self.url = url
        isAccessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if isAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

public final class RecordingFolderStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let bookmarkKey: String
    private let bookmarkCoder: any SecurityScopedBookmarkCoding

    public init(
        defaults: UserDefaults = .standard,
        bookmarkKey: String = "recordingFolderBookmark",
        bookmarkCoder: any SecurityScopedBookmarkCoding =
            SystemSecurityScopedBookmarkCoder()
    ) {
        self.defaults = defaults
        self.bookmarkKey = bookmarkKey
        self.bookmarkCoder = bookmarkCoder
    }

    public func save(_ url: URL) throws -> ScopedFolderAccess {
        let bookmark = try bookmarkCoder.bookmark(for: url)
        defaults.set(bookmark, forKey: bookmarkKey)
        return ScopedFolderAccess(url: url)
    }

    public func resolve() throws -> ScopedFolderAccess? {
        guard let bookmark = defaults.data(forKey: bookmarkKey) else { return nil }
        let resolution = try bookmarkCoder.resolve(bookmark)
        guard !resolution.isStale else {
            defaults.removeObject(forKey: bookmarkKey)
            throw RecordingFolderStoreError.staleBookmark
        }
        return ScopedFolderAccess(url: resolution.url)
    }

    public func clear() {
        defaults.removeObject(forKey: bookmarkKey)
    }
}
