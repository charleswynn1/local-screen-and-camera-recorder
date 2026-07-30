#!/bin/bash

set -euo pipefail

identity_name="Local Recorder Development"
keychain_path="$HOME/Library/Keychains/LocalRecorderDevelopment.keychain-db"
keychain_password="local-recorder-development-keychain"

if [[ "$(basename "$keychain_path")" != "LocalRecorderDevelopment.keychain-db" ]]; then
    printf 'Refusing to manage an unexpected keychain path: %s\n' \
        "$keychain_path" >&2
    exit 1
fi

keychain_is_searchable() {
    security list-keychains -d user \
        | tr -d ' "' \
        | grep -Fxq "$keychain_path"
}

add_keychain_to_search_list() {
    local existing=()
    local candidate
    while IFS= read -r candidate; do
        candidate="${candidate#*\"}"
        candidate="${candidate%\"*}"
        if [[ -n "$candidate" && "$candidate" != "$keychain_path" ]]; then
            existing+=("$candidate")
        fi
    done < <(security list-keychains -d user)
    security list-keychains -d user -s "$keychain_path" "${existing[@]}"
}

identity_is_ready() {
    local identities
    identities="$(security find-identity \
        -v \
        -p codesigning \
        "$keychain_path" 2>/dev/null)"
    [[ "$identities" == *"\"$identity_name\""* ]]
}

if [[ -f "$keychain_path" ]]; then
    security unlock-keychain -p "$keychain_password" "$keychain_path"
    security set-keychain-settings "$keychain_path"
    if ! keychain_is_searchable; then
        add_keychain_to_search_list
    fi
    if identity_is_ready; then
        printf '%s\n' \
            "Local Recorder development signing is ready." \
            "The certificate is machine-local and is never used for Release builds."
        exit 0
    fi

    security delete-keychain "$keychain_path"
fi

umask 077
temporary_directory="$(mktemp -d \
    "${TMPDIR:-/tmp}/local-recorder-development-signing.XXXXXX")"
private_key="$temporary_directory/private-key.pem"
certificate="$temporary_directory/certificate.pem"
identity_archive="$temporary_directory/identity.p12"

cleanup() {
    rm -f "$private_key" "$certificate" "$identity_archive"
    rmdir "$temporary_directory" 2>/dev/null || true
}
trap cleanup EXIT

p12_password="$(/usr/bin/openssl rand -hex 24)"

/usr/bin/openssl req \
    -new \
    -x509 \
    -newkey rsa:2048 \
    -sha256 \
    -nodes \
    -days 3650 \
    -subj "/CN=$identity_name/O=Charles Wynn Development" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$private_key" \
    -out "$certificate" \
    >/dev/null 2>&1

/usr/bin/openssl pkcs12 \
    -export \
    -inkey "$private_key" \
    -in "$certificate" \
    -name "$identity_name" \
    -out "$identity_archive" \
    -passout "pass:$p12_password"

security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$identity_archive" \
    -k "$keychain_path" \
    -f pkcs12 \
    -P "$p12_password" \
    -T /usr/bin/codesign \
    >/dev/null
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -t private \
    -k "$keychain_password" \
    "$keychain_path" \
    >/dev/null
add_keychain_to_search_list

printf '%s\n' \
    "macOS may now request authentication once." \
    "Approve it to trust this machine-local certificate for code signing."
security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$keychain_path" \
    "$certificate"

if ! identity_is_ready; then
    printf '%s\n' \
        "The development signing identity could not be validated." \
        "Run this script again and approve the macOS authentication request." >&2
    exit 1
fi

printf '%s\n' \
    "Local Recorder development signing is ready." \
    "Quit and reopen Local Recorder, then grant Screen Recording once." \
    "Future Debug rebuilds will retain the same macOS privacy identity."
