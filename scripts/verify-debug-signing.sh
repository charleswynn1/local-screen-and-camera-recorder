#!/bin/bash

set -euo pipefail

recorder_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="${1:-${TMPDIR:-/tmp}/local-recorder-signing-verification}"
app_path="$derived_data/Build/Products/Debug/Local Recorder.app"
expected_identity="Local Recorder Development"

build_setting() {
    local configuration="$1"
    local setting="$2"
    xcodebuild -project "$recorder_root/LocalRecorder.xcodeproj" \
        -target LocalRecorder \
        -configuration "$configuration" \
        -showBuildSettings \
        CODE_SIGNING_ALLOWED=NO 2>/dev/null \
        | sed -n "s/^[[:space:]]*$setting = //p" \
        | sed -n '1p'
}

debug_style="$(build_setting Debug CODE_SIGN_STYLE)"
debug_identity="$(build_setting Debug CODE_SIGN_IDENTITY)"
debug_flags="$(build_setting Debug OTHER_CODE_SIGN_FLAGS)"
release_identity="$(build_setting Release CODE_SIGN_IDENTITY)"

if [[ "$debug_style" != "Manual" ]]; then
    printf 'Debug must use manual signing, found: %s\n' "$debug_style" >&2
    exit 1
fi
if [[ "$debug_identity" != "$expected_identity" ]]; then
    printf 'Unexpected Debug signing identity: %s\n' "$debug_identity" >&2
    exit 1
fi
if [[ -n "$debug_flags" ]]; then
    printf 'Debug must not override its designated requirement: %s\n' "$debug_flags" >&2
    exit 1
fi
if [[ "$release_identity" == "$expected_identity" ]]; then
    printf 'The local development identity must never be used for Release.\n' >&2
    exit 1
fi

available_identities="$(security find-identity -v -p codesigning)"
if [[ "$available_identities" != *"\"$expected_identity\""* ]]; then
    printf '%s\n' \
        "Debug signing configuration verified." \
        "The local identity is not installed, so the rebuild check was skipped." \
        "Run scripts/setup-development-signing.sh to enable it."
    exit 0
fi

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
    if [[ "$requirement" != *'identifier "com.charleswynn.localrecorder"'* \
        || "$requirement" != *'certificate root = H"'* ]]; then
        printf 'Debug requirement is not certificate-backed:\n%s\n' \
            "$requirement" >&2
        exit 1
    fi
    local signature_details
    signature_details="$(codesign -dvvv "$app_path" 2>&1)"
    if [[ "$signature_details" != *"Authority=$expected_identity"* ]]; then
        printf 'Debug app was not signed by %s.\n' "$expected_identity" >&2
        exit 1
    fi
}

build_version 1
verify_signature
first_requirement="$(signature_requirement)"
first_hash="$(signature_hash)"

build_version 2
verify_signature
second_requirement="$(signature_requirement)"
second_hash="$(signature_hash)"

if [[ "$first_requirement" != "$second_requirement" ]]; then
    printf 'Debug designated requirement changed across rebuilds.\n' >&2
    exit 1
fi
if [[ -z "$first_hash" || -z "$second_hash" || "$first_hash" == "$second_hash" ]]; then
    printf 'Expected different code hashes across rebuilt app versions.\n' >&2
    exit 1
fi

printf 'Certificate-backed Debug identity verified across code hashes %s and %s.\n' \
    "$first_hash" \
    "$second_hash"
