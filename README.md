# Local Recorder

Local Recorder is a private, offline macOS screen-and-camera recorder. It records one display, one window, a display region, the active camera, or screen and camera together. Recordings are H.264/AAC MP4 files written directly to a folder chosen by the user.

## v0.1 capabilities

- Screen-only, camera-only, and screen-plus-camera modes
- Full-display, single-window, and one-display region capture
- Built-in, USB/UVC, and Continuity Camera selection
- Movable small, medium, or large rounded camera overlay
- Independent system-audio and microphone controls with live level meters
- 720p/30, 1080p/30, and up-to-4K/60 presets with hardware preflight
- Three-second countdown, pause/resume, timer, and global hot keys
- Cursor and mouse-click capture controls
- Folder-backed recording library with preview, rename, share, Finder reveal, and Move to Trash
- Sandboxed, local-only operation with no account, analytics, uploads, or network entitlement
- Interrupted-file recovery using fragmented MP4 output

## Requirements

- Apple Silicon MacBook
- macOS 15 or later
- Full Xcode with the macOS 15 SDK or later
- Apple Developer Program credentials only for Developer ID signing and notarization

The command-line tools currently selected on the development Mac can compile and exercise `RecorderCore`, but they do not include the Xcode UI-test runner or app archiver. Install and select full Xcode before running the Xcode scheme or producing a DMG.

## Development

Open `LocalRecorder.xcodeproj`, select the **LocalRecorder** scheme, and run the app. Xcode will apply the sandbox, camera, microphone, user-selected-file, and hardened-runtime settings.

Command-line validation:

```sh
swift build
swift test
swift run RecorderCoreHarness
```

`RecorderCoreHarness` is intentionally independent of XCTest. It validates configuration, geometry, pause-aware timestamps, the recording state machine, and a real H.264 MP4 encode. The regular test target adds unit, protocol-fake pipeline, H.264/AAC fixture, interrupted-recovery, bookmark, disk-pressure, and library-operation regression suites. The Xcode scheme also runs deterministic UI tests without opening TCC or ScreenCaptureKit system pickers.

Screen, camera, and microphone behavior depends on macOS TCC permissions and physical devices, so releases must also pass [the manual test matrix](docs/MANUAL_TEST_MATRIX.md).

## Architecture

- `RecorderCore` owns the source-of-truth recording models and actor-isolated state machine.
- ScreenCaptureKit supplies display/window/region frames and system audio.
- AVFoundation supplies camera and microphone samples.
- A Metal-backed Core Image compositor produces the final screen/camera frame.
- `PCMAudioMixer` aligns sources at 48 kHz, prioritizes narration, and writes one AAC track.
- `AssetRecordingWriter` writes fragmented staging MP4s and atomically publishes validated files.
- The selected folder is the recording library's source of truth; only derived previews are cached.

Sample queues are bounded. Late video frames are dropped rather than accumulating memory, while timestamps remain continuous across pause/resume.

## Website distribution

The website is maintained separately. A tagged release runs `.github/workflows/release.yml`, which:

1. Imports a Developer ID Application certificate into an ephemeral keychain.
2. Archives an arm64 hardened-runtime build.
3. Creates and notarizes a versioned DMG.
4. Staples and validates the notarization ticket.
5. Publishes the DMG and SHA-256 checksum to GitHub Releases.

Required repository secrets:

- `APPLE_TEAM_ID`
- `DEVELOPER_ID_CERTIFICATE_P12_BASE64`
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `BUILD_KEYCHAIN_PASSWORD`
- `APP_STORE_CONNECT_KEY_P8_BASE64`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`

The first public release remains blocked until those credentials exist. Keep the app sandboxed and free of private APIs so a later Mac App Store build can reuse the same capture and storage architecture.
