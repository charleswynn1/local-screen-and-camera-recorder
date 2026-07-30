#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID to the Apple Developer team identifier.}"
: "${APP_STORE_CONNECT_KEY_PATH:?Set APP_STORE_CONNECT_KEY_PATH to the notarization API key file.}"
: "${APP_STORE_CONNECT_KEY_ID:?Set APP_STORE_CONNECT_KEY_ID.}"
: "${APP_STORE_CONNECT_ISSUER_ID:?Set APP_STORE_CONNECT_ISSUER_ID.}"

VERSION="${VERSION:-0.1.0}"
OUTPUT_DIR="${PROJECT_ROOT}/build/release"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/local-recorder-release.XXXXXX")"
ARCHIVE_PATH="${WORK_DIR}/LocalRecorder.xcarchive"
EXPORT_DIR="${WORK_DIR}/export"
DMG_ROOT="${WORK_DIR}/dmg"
EXPORT_OPTIONS="${WORK_DIR}/ExportOptions.plist"
DMG_PATH="${OUTPUT_DIR}/LocalRecorder-${VERSION}-arm64.dmg"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

mkdir -p "${OUTPUT_DIR}" "${EXPORT_DIR}" "${DMG_ROOT}"
cp "${PROJECT_ROOT}/Config/ExportOptions.plist" "${EXPORT_OPTIONS}"
/usr/libexec/PlistBuddy -c "Set :teamID ${APPLE_TEAM_ID}" "${EXPORT_OPTIONS}"

xcodebuild archive \
  -project "${PROJECT_ROOT}/LocalRecorder.xcodeproj" \
  -scheme LocalRecorder \
  -configuration Release \
  -destination "generic/platform=macOS,arch=arm64" \
  -archivePath "${ARCHIVE_PATH}" \
  DEVELOPMENT_TEAM="${APPLE_TEAM_ID}" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" \
  MARKETING_VERSION="${VERSION}"

xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_DIR}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}"

APP_PATH="${EXPORT_DIR}/Local Recorder.app"
test -d "${APP_PATH}"
APP_EXECUTABLE="${APP_PATH}/Contents/MacOS/Local Recorder"
test -x "${APP_EXECUTABLE}"
test "$(lipo -archs "${APP_EXECUTABLE}")" = "arm64"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

cp -R "${APP_PATH}" "${DMG_ROOT}/Local Recorder.app"
ln -s /Applications "${DMG_ROOT}/Applications"

hdiutil create \
  -volname "Local Recorder" \
  -srcfolder "${DMG_ROOT}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

codesign \
  --force \
  --timestamp \
  --sign "Developer ID Application" \
  "${DMG_PATH}"

xcrun notarytool submit "${DMG_PATH}" \
  --key "${APP_STORE_CONNECT_KEY_PATH}" \
  --key-id "${APP_STORE_CONNECT_KEY_ID}" \
  --issuer "${APP_STORE_CONNECT_ISSUER_ID}" \
  --wait

xcrun stapler staple "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
codesign --verify --strict --verbose=2 "${DMG_PATH}"
spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG_PATH}"
(
  cd "${OUTPUT_DIR}"
  shasum -a 256 "$(basename "${DMG_PATH}")" \
    > "$(basename "${DMG_PATH}").sha256"
)

echo "Created ${DMG_PATH}"
echo "Created ${DMG_PATH}.sha256"
