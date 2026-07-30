@preconcurrency import AVFoundation
import Foundation

public enum DeviceCatalog {
    public static func cameras() -> [CaptureDeviceDescriptor] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        let preferredID = AVCaptureDevice.systemPreferredCamera?.uniqueID
        return deduplicated(session.devices).map {
            CaptureDeviceDescriptor(
                id: $0.uniqueID,
                name: $0.localizedName,
                kind: .camera,
                isSystemPreferred: $0.uniqueID == preferredID
            )
        }.sorted {
            if $0.isSystemPreferred != $1.isSystemPreferred {
                return $0.isSystemPreferred
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public static func microphones() -> [CaptureDeviceDescriptor] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let preferredID = AVCaptureDevice.default(for: .audio)?.uniqueID
        return deduplicated(session.devices).map {
            CaptureDeviceDescriptor(
                id: $0.uniqueID,
                name: $0.localizedName,
                kind: .microphone,
                isSystemPreferred: $0.uniqueID == preferredID
            )
        }.sorted {
            if $0.isSystemPreferred != $1.isSystemPreferred {
                return $0.isSystemPreferred
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public static func preferredCameraCaptureSize(
        deviceID: String?,
        preset: QualityPreset
    ) -> CGSize? {
        guard let device = camera(deviceID: deviceID) else { return nil }
        let requiredFrameRate = Double(preset.framesPerSecond)
        let maximum = preset.maximumSize
        let candidates = device.formats.compactMap { format -> CGSize? in
            let dimensions = CMVideoFormatDescriptionGetDimensions(
                format.formatDescription
            )
            let size = CGSize(
                width: Int(dimensions.width),
                height: Int(dimensions.height)
            )
            guard size.width <= maximum.width,
                  size.height <= maximum.height,
                  format.videoSupportedFrameRateRanges.contains(where: {
                      $0.maxFrameRate + 0.1 >= requiredFrameRate
                          && $0.minFrameRate - 0.1 <= requiredFrameRate
                  }) else {
                return nil
            }
            return size
        }
        return candidates.max {
            $0.width * $0.height < $1.width * $1.height
        }
    }

    public static func highQualityCameraFailureReason(
        deviceID: String?
    ) -> String? {
        guard let device = camera(deviceID: deviceID) else {
            return ConfigurationIssue.missingCamera.message
        }
        guard preferredCameraCaptureSize(
            deviceID: device.uniqueID,
            preset: .high
        ) != nil else {
            return "“\(device.localizedName)” does not provide a 60 fps format for High quality."
        }
        return nil
    }

    private static func deduplicated(_ devices: [AVCaptureDevice]) -> [AVCaptureDevice] {
        var seen = Set<String>()
        return devices.filter { seen.insert($0.uniqueID).inserted }
    }

    private static func camera(deviceID: String?) -> AVCaptureDevice? {
        deviceID.flatMap(AVCaptureDevice.init(uniqueID:))
            ?? AVCaptureDevice.systemPreferredCamera
            ?? AVCaptureDevice.default(for: .video)
    }
}

public enum PermissionService {
    public static func status(for kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .screen:
            return CGPreflightScreenCaptureAccess() ? .authorized : .notDetermined
        case .camera:
            return map(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            return map(AVCaptureDevice.authorizationStatus(for: .audio))
        }
    }

    public static func request(_ kind: PermissionKind) async -> Bool {
        switch kind {
        case .screen:
            return CGRequestScreenCaptureAccess()
        case .camera:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .denied
        }
    }
}
