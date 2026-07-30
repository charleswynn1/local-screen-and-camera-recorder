# Local Recorder manual test matrix

Run this matrix on a release-signed Apple Silicon MacBook with macOS 15 before publishing a DMG. Reset TCC between permission scenarios with a disposable development bundle identifier; never reset a user's production permissions.

## Permissions and onboarding

- For a Debug build, run `scripts/setup-development-signing.sh`, grant Screen Recording, rebuild with a different `CURRENT_PROJECT_VERSION`, relaunch, and confirm the grant remains active.
- Launch without Screen Recording, Camera, or Microphone permission.
- Confirm each prompt appears only when the selected mode needs it.
- Deny each permission and confirm recording remains disabled with recovery guidance.
- Grant Screen Recording, restart when macOS requests it, and confirm the status refreshes.
- Change the recording folder, relaunch, and verify the security-scoped bookmark resolves.
- Revoke folder access or move the folder and verify the app requests a replacement.

## Capture sources

- Record the built-in display at Compact, Standard, and High quality.
- Record a second display and confirm the floating controller is excluded.
- Record a normal window, a window partially off-screen, and a window with child panels.
- Close the selected window during recording and verify a playable partial result is finalized.
- Select regions at every display edge and with Retina scaling enabled.
- Attempt a cross-display drag and confirm selection remains constrained to its starting display.
- Verify cursor visibility and click highlighting independently.

## Camera and audio

- Test the built-in camera, a USB/UVC camera, and Continuity Camera.
- Test built-in and external microphones.
- Verify the preview is mirrored and the encoded camera is naturally oriented.
- During camera-only recording, verify the floating controller shows the live camera, can collapse without interrupting capture, and can restore the live preview.
- Verify small, medium, and large overlays in every corner.
- Disconnect the camera during combined capture; screen capture must continue without the overlay.
- Disconnect the camera during camera-only capture; the file must finalize.
- Disconnect the microphone; video and system audio must continue.
- Record system audio only, microphone only, both, and neither.
- Confirm Local Recorder's own UI sounds are excluded.

## State and resilience

- Cancel the three-second countdown with Escape and the Cancel button.
- Pause for at least one minute, resume, and verify no frozen or silent gap exists.
- Use Control–Option–R and Control–Option–P while another app is focused.
- Quit during recording and confirm the file finalizes before termination.
- Sleep and lock the Mac during recording and confirm graceful finalization.
- Simulate low disk space and confirm capture stops before the volume is exhausted.
- Force-quit after at least 15 seconds; relaunch and confirm fragment recovery or cleanup guidance.
- Complete 30-minute runs for screen, camera, and combined modes.
- Complete a two-hour combined recording; verify memory remains bounded, at least 99% of scheduled Standard frames are written, and A/V drift is below 100 ms.

## Library and distribution

- Preview, rename, share, reveal, and move a recording to Trash.
- Rename a recording to an existing name and verify the original is preserved.
- Add an external MP4 to the selected folder and confirm the folder-backed library refreshes safely.
- Download the DMG through a browser on a clean Mac.
- Verify the stapled notarization ticket, Gatekeeper launch, drag-to-Applications flow, first-run permissions, and SHA-256 checksum.
