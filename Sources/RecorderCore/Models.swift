import CoreGraphics
import CoreMedia
import Foundation

public enum CaptureMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case screen
    case camera
    case combined

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screen: "Screen Only"
        case .camera: "Camera Only"
        case .combined: "Screen + Camera"
        }
    }

    public var systemImage: String {
        switch self {
        case .screen: "rectangle.on.rectangle"
        case .camera: "video"
        case .combined: "person.crop.rectangle.badge.plus"
        }
    }

    public var needsScreen: Bool { self != .camera }
    public var needsCamera: Bool { self != .screen }
}

public enum ScreenSelectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case display
    case window
    case region

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .display: "Full Screen"
        case .window: "Window"
        case .region: "Region"
        }
    }

    public var systemImage: String {
        switch self {
        case .display: "display"
        case .window: "macwindow"
        case .region: "viewfinder"
        }
    }
}

public struct NormalizedRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    public var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
            && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1.000_001 && y + height <= 1.000_001
    }

    public func clamped() -> NormalizedRect {
        let safeX = min(max(x, 0), 1)
        let safeY = min(max(y, 0), 1)
        return NormalizedRect(
            x: safeX,
            y: safeY,
            width: min(max(width, 0), 1 - safeX),
            height: min(max(height, 0), 1 - safeY)
        )
    }

    public func denormalized(in size: CGSize) -> CGRect {
        CGRect(
            x: x * size.width,
            y: y * size.height,
            width: width * size.width,
            height: height * size.height
        )
    }

    public func denormalizedInPixels(
        displayPointSize: CGSize,
        pointPixelScale: CGFloat
    ) -> CGRect {
        let points = denormalized(in: displayPointSize)
        let scale = max(1, pointPixelScale)
        return CGRect(
            x: points.minX * scale,
            y: points.minY * scale,
            width: points.width * scale,
            height: points.height * scale
        )
    }

    public static func from(displayLocalAppKitRect rect: CGRect, displaySize: CGSize) -> NormalizedRect {
        guard displaySize.width > 0, displaySize.height > 0 else { return .full }
        let standardized = rect.standardized
        let topLeftY = displaySize.height - standardized.maxY
        return NormalizedRect(
            x: standardized.minX / displaySize.width,
            y: topLeftY / displaySize.height,
            width: standardized.width / displaySize.width,
            height: standardized.height / displaySize.height
        ).clamped()
    }
}

public enum ScreenSelection: Codable, Equatable, Sendable {
    case display(id: UInt32?, name: String)
    case window(id: UInt32?, title: String)
    case region(displayID: UInt32?, displayName: String, rect: NormalizedRect)

    public var kind: ScreenSelectionKind {
        switch self {
        case .display: .display
        case .window: .window
        case .region: .region
        }
    }

    public var label: String {
        switch self {
        case let .display(_, name): name
        case let .window(_, title): title
        case let .region(_, displayName, _): "\(displayName) Region"
        }
    }
}

public enum QualityPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case high

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .compact: "Compact"
        case .standard: "Standard"
        case .high: "High"
        }
    }

    public var detail: String {
        switch self {
        case .compact: "Up to 720p · 30 fps"
        case .standard: "Up to 1080p · 30 fps"
        case .high: "Up to 4K · 60 fps"
        }
    }

    public var maximumSize: CGSize {
        switch self {
        case .compact: CGSize(width: 1_280, height: 720)
        case .standard: CGSize(width: 1_920, height: 1_080)
        case .high: CGSize(width: 3_840, height: 2_160)
        }
    }

    public var framesPerSecond: Int32 {
        switch self {
        case .compact, .standard: 30
        case .high: 60
        }
    }

    public var videoBitRate: Int {
        switch self {
        case .compact: 4_000_000
        case .standard: 8_000_000
        case .high: 32_000_000
        }
    }
}

public enum OverlayCorner: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    public var id: String { rawValue }
}

public enum OverlaySize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large

    public var id: String { rawValue }

    public var title: String { rawValue.capitalized }

    public var widthFraction: CGFloat {
        switch self {
        case .small: 0.18
        case .medium: 0.25
        case .large: 0.33
        }
    }
}

public struct OverlayLayout: Codable, Equatable, Sendable {
    public var corner: OverlayCorner
    public var size: OverlaySize

    public init(corner: OverlayCorner = .bottomTrailing, size: OverlaySize = .medium) {
        self.corner = corner
        self.size = size
    }

    /// The overlay frame normalized to a canonical 16:9 canvas. The origin uses
    /// the compositor's bottom-left coordinate system.
    public var normalizedFrame: NormalizedRect {
        normalizedFrame(in: CGSize(width: 1_600, height: 900))
    }

    public func normalizedFrame(
        in canvasSize: CGSize,
        marginFraction: CGFloat = 0.025
    ) -> NormalizedRect {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            return .full
        }
        let frame = resolvedFrame(
            in: canvasSize,
            marginFraction: marginFraction
        )
        return NormalizedRect(
            x: frame.minX / canvasSize.width,
            y: frame.minY / canvasSize.height,
            width: frame.width / canvasSize.width,
            height: frame.height / canvasSize.height
        ).clamped()
    }

    public func frame(in canvasSize: CGSize, marginFraction: CGFloat = 0.025) -> CGRect {
        normalizedFrame(
            in: canvasSize,
            marginFraction: marginFraction
        ).denormalized(in: canvasSize)
    }

    private func resolvedFrame(
        in canvasSize: CGSize,
        marginFraction: CGFloat
    ) -> CGRect {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        let width = canvasSize.width * size.widthFraction
        let height = width * 9 / 16
        let margin = max(12, min(canvasSize.width, canvasSize.height) * marginFraction)

        let x: CGFloat
        switch corner {
        case .topLeading, .bottomLeading:
            x = margin
        case .topTrailing, .bottomTrailing:
            x = canvasSize.width - width - margin
        }

        let y: CGFloat
        switch corner {
        case .bottomLeading, .bottomTrailing:
            y = margin
        case .topLeading, .topTrailing:
            y = canvasSize.height - height - margin
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct RecordingConfiguration: Codable, Equatable, Sendable {
    public var mode: CaptureMode
    public var screenSelection: ScreenSelection?
    public var cameraDeviceID: String?
    public var microphoneDeviceID: String?
    public var capturesSystemAudio: Bool
    public var capturesMicrophone: Bool
    public var quality: QualityPreset
    public var overlay: OverlayLayout
    public var showsCursor: Bool
    public var showsMouseClicks: Bool

    public init(
        mode: CaptureMode = .combined,
        screenSelection: ScreenSelection? = nil,
        cameraDeviceID: String? = nil,
        microphoneDeviceID: String? = nil,
        capturesSystemAudio: Bool = true,
        capturesMicrophone: Bool = true,
        quality: QualityPreset = .standard,
        overlay: OverlayLayout = OverlayLayout(),
        showsCursor: Bool = true,
        showsMouseClicks: Bool = false
    ) {
        self.mode = mode
        self.screenSelection = screenSelection
        self.cameraDeviceID = cameraDeviceID
        self.microphoneDeviceID = microphoneDeviceID
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.quality = quality
        self.overlay = overlay
        self.showsCursor = showsCursor
        self.showsMouseClicks = showsMouseClicks
        normalizeForMode()
    }

    public mutating func applyDefaults(for mode: CaptureMode) {
        self.mode = mode
        switch mode {
        case .screen:
            capturesSystemAudio = true
            capturesMicrophone = false
        case .camera:
            capturesSystemAudio = false
            capturesMicrophone = true
        case .combined:
            capturesSystemAudio = true
            capturesMicrophone = true
        }
        normalizeForMode()
    }

    public mutating func normalizeForMode() {
        if !mode.needsScreen {
            capturesSystemAudio = false
            screenSelection = nil
        }
    }

    public func validationIssues(hasResolvedScreenTarget: Bool) -> [ConfigurationIssue] {
        var issues = [ConfigurationIssue]()
        if mode.needsScreen && (!hasResolvedScreenTarget || screenSelection == nil) {
            issues.append(.missingScreenSelection)
        }
        if mode.needsCamera && cameraDeviceID == nil {
            issues.append(.missingCamera)
        }
        if capturesMicrophone && microphoneDeviceID == nil {
            issues.append(.missingMicrophone)
        }
        if case let .region(_, _, rect) = screenSelection, !rect.isValid {
            issues.append(.invalidRegion)
        }
        return issues
    }
}

public enum ConfigurationIssue: String, Error, Equatable, Sendable {
    case missingScreenSelection
    case missingCamera
    case missingMicrophone
    case invalidRegion
    case invalidOutputSize
    case highQualityUnavailable
    case missingDestination

    public var message: String {
        switch self {
        case .missingScreenSelection: "Choose a screen, window, or region."
        case .missingCamera: "Choose an available camera."
        case .missingMicrophone: "Choose an available microphone or turn microphone recording off."
        case .invalidRegion: "Choose a region with a non-zero size inside one display."
        case .invalidOutputSize: "The selected source cannot produce a valid video size."
        case .highQualityUnavailable: "This Mac cannot encode the selected source at High quality."
        case .missingDestination: "Choose a recording folder."
        }
    }
}

public enum RecordingPhase: String, Codable, Equatable, Sendable {
    case idle
    case selecting
    case countingDown
    case recording
    case paused
    case finalizing
    case completed
    case failed
}

public struct RecordingSnapshot: Equatable, Sendable {
    public var phase: RecordingPhase
    public var countdown: Int?
    public var outputURL: URL?
    public var message: String?

    public init(
        phase: RecordingPhase,
        countdown: Int? = nil,
        outputURL: URL? = nil,
        message: String? = nil
    ) {
        self.phase = phase
        self.countdown = countdown
        self.outputURL = outputURL
        self.message = message
    }

    public static let idle = RecordingSnapshot(phase: .idle)
}

public struct RecordingArtifact: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let createdAt: Date
    public let duration: TimeInterval
    public let fileSize: Int64

    public init(url: URL, createdAt: Date, duration: TimeInterval, fileSize: Int64) {
        self.url = url
        self.createdAt = createdAt
        self.duration = duration
        self.fileSize = fileSize
    }
}

public struct CaptureDeviceDescriptor: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case camera
        case microphone
    }

    public let id: String
    public let name: String
    public let kind: Kind
    public let isSystemPreferred: Bool

    public init(id: String, name: String, kind: Kind, isSystemPreferred: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isSystemPreferred = isSystemPreferred
    }
}

public enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case screen
    case camera
    case microphone

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum PermissionStatus: String, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

public enum PermissionGrantAction: Equatable, Sendable {
    case request
    case openSettings
    case none
}

public enum PrivacySettingsLink {
    public static let root = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
    )!

    public static func url(for kind: PermissionKind) -> URL {
        let anchor = switch kind {
        case .screen:
            "Privacy_ScreenCapture"
        case .camera:
            "Privacy_Camera"
        case .microphone:
            "Privacy_Microphone"
        }
        return URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)"
        )!
    }

    public static func grantAction(for status: PermissionStatus) -> PermissionGrantAction {
        switch status {
        case .notDetermined:
            .request
        case .denied, .restricted:
            .openSettings
        case .authorized:
            .none
        }
    }

    public static func resolvedStatus(
        system: PermissionStatus,
        cached: PermissionStatus?
    ) -> PermissionStatus {
        if system == .authorized || cached != .denied {
            return system
        }
        return .denied
    }
}

public struct RecordingRequest: @unchecked Sendable {
    public let configuration: RecordingConfiguration
    public let screenTarget: ScreenCaptureTarget?
    public let destinationFolder: URL

    public init(
        configuration: RecordingConfiguration,
        screenTarget: ScreenCaptureTarget?,
        destinationFolder: URL
    ) {
        self.configuration = configuration
        self.screenTarget = screenTarget
        self.destinationFolder = destinationFolder
    }
}

public enum PipelineEvent: Equatable, Sendable {
    case warning(String)
    case stopRequested(String)
    case fatal(String)
}

public enum AudioSourceKind: Sendable {
    case system
    case microphone
}

public struct VideoSample: @unchecked Sendable {
    public let sampleBuffer: CMSampleBuffer

    public init(_ sampleBuffer: CMSampleBuffer) {
        self.sampleBuffer = sampleBuffer
    }
}

public struct RecordingPreviewFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let presentationTime: CMTime

    public init(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime
    ) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
    }
}

public struct AudioSample: @unchecked Sendable {
    public let source: AudioSourceKind
    public let sampleBuffer: CMSampleBuffer

    public init(source: AudioSourceKind, sampleBuffer: CMSampleBuffer) {
        self.source = source
        self.sampleBuffer = sampleBuffer
    }
}
