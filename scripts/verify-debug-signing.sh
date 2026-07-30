#!/bin/bash

set -euo pipefail

recorder_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="${1:-${TMPDIR:-/tmp}/local-recorder-signing-verification}"
app_path="$derived_data/Build/Products/Debug/Local Recorder.app"
expected_requirement='designated => identifier "com.charleswynn.localrecorder"'

build_version() {
    local version="$1"
    xcodebuild -quiet build \
        -project "$recorder_root/LocalRecorder.xcodeproj" \
        -scheme LocalRecorder \
        -configuration Debug \
        -derivedDataPath "$derived_data" \
        -destination "platform=macOS,arch=arm64" \
        ONLY_ACTIVE_ARCH=YES \
        ARCHS=arm64 \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="-" \
        DEVELOPMENT_TEAM="" \
        CURRENT_PROJECT_VERSION="$version"
}

signature_requirement() {
    codesign -d --requirements - "$app_path" 2>&1 \
        | sed -n '/^designated => /p'
}

signature_hash() {
    codesign -dvvv "$app_path" 2>&1 \
        | sed -n 's/^CDHash=//p' \
        | head -n 1
}

verify_signature() {
    codesign --verify --deep --strict --verbose=4 "$app_path"
    local requirement
    requirement="$(signature_requirement)"
    if [[ "$requirement" != "$expected_requirement" ]]; then
        printf 'Unexpected Debug designated requirement:\n%s\n' "$requirement" >&2
        exit 1
    fi
}

build_version 1
verify_signature
first_hash="$(signature_hash)"

build_version 2
verify_signature
second_hash="$(signature_hash)"

if [[ -z "$first_hash" || -z "$second_hash" || "$first_hash" == "$second_hash" ]]; then
    printf 'Expected different code hashes across rebuilt app versions.\n' >&2
    exit 1
fi

printf 'Stable Debug requirement verified across code hashes %s and %s.\n' \
    "$first_hash" \
    "$second_hash"
