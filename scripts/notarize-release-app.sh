#!/bin/zsh

emulate -L zsh
set -euo pipefail

readonly PROJECT_ROOT="${0:A:h:h}"
readonly VERSION="${1:-}"
readonly NOTARY_PROFILE="${MEMORY_WATCHER_NOTARY_PROFILE:-MemoryWatcher-Notarization}"
readonly NOTARY_KEYCHAIN="${MEMORY_WATCHER_NOTARY_KEYCHAIN:-}"
readonly EXISTING_SUBMISSION_ID="${MEMORY_WATCHER_NOTARY_SUBMISSION_ID:-}"

typeset -a NOTARY_AUTHENTICATION
NOTARY_AUTHENTICATION=(--keychain-profile "${NOTARY_PROFILE}")
if [[ -n "${NOTARY_KEYCHAIN}" ]]; then
    NOTARY_AUTHENTICATION+=(--keychain "${NOTARY_KEYCHAIN}")
fi

[[ "${VERSION}" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || {
    print -u2 -- "version must use major.minor.patch"
    exit 2
}
[[ -n "${NOTARY_PROFILE}" ]] || {
    print -u2 -- "notary keychain profile must not be empty"
    exit 3
}

readonly APP_PATH="${PROJECT_ROOT}/.build/MemoryWatcher-${VERSION}.app"
readonly ARCHIVE_PATH="${PROJECT_ROOT}/.build/MemoryWatcher-${VERSION}.zip"
readonly RESPONSE_PATH="${PROJECT_ROOT}/.build/MemoryWatcher-${VERSION}.notary.json"
readonly LOG_PATH="${PROJECT_ROOT}/.build/MemoryWatcher-${VERSION}.notary-log.json"
readonly ENTITLEMENTS_PATH="${PROJECT_ROOT}/.build/MemoryWatcher-${VERSION}.entitlements.plist"

[[ -d "${APP_PATH}" ]] || {
    print -u2 -- "release app is unavailable: run build-release-app.sh first"
    exit 4
}
[[ -f "${ARCHIVE_PATH}" ]] || {
    print -u2 -- "release archive is unavailable: run build-release-app.sh first"
    exit 5
}

/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

readonly SIGNING_DETAILS="$(/usr/bin/codesign \
    --display \
    --verbose=4 \
    "${APP_PATH}" 2>&1)"
[[ "${SIGNING_DETAILS}" == *"Authority=Developer ID Application:"* ]] || {
    print -u2 -- "release app is not signed with Developer ID Application"
    exit 6
}
[[ "${SIGNING_DETAILS}" == *"Runtime Version="* ]] || {
    print -u2 -- "release app does not declare hardened runtime"
    exit 7
}
[[ "${SIGNING_DETAILS}" == *"Timestamp="* ]] || {
    print -u2 -- "release app does not contain a secure timestamp"
    exit 8
}

: > "${ENTITLEMENTS_PATH}"
/usr/bin/codesign \
    --display \
    --entitlements :- \
    "${APP_PATH}" > "${ENTITLEMENTS_PATH}" 2>/dev/null || true
if [[ -s "${ENTITLEMENTS_PATH}" ]] \
    && [[ "$(/usr/bin/plutil \
        -extract com.apple.security.get-task-allow \
        raw \
        -o - \
        "${ENTITLEMENTS_PATH}" 2>/dev/null || true)" == "true" ]]
then
    print -u2 -- "release app must not enable com.apple.security.get-task-allow"
    exit 9
fi

if [[ -n "${EXISTING_SUBMISSION_ID}" ]]; then
    /usr/bin/xcrun notarytool info \
        "${EXISTING_SUBMISSION_ID}" \
        "${NOTARY_AUTHENTICATION[@]}" \
        --output-format json > "${RESPONSE_PATH}"
else
    /usr/bin/xcrun notarytool submit \
        "${ARCHIVE_PATH}" \
        "${NOTARY_AUTHENTICATION[@]}" \
        --wait \
        --output-format json > "${RESPONSE_PATH}"
fi

readonly STATUS="$(/usr/bin/plutil -extract status raw -o - "${RESPONSE_PATH}")"
readonly SUBMISSION_ID="$(/usr/bin/plutil -extract id raw -o - "${RESPONSE_PATH}")"

/usr/bin/xcrun notarytool log \
    "${SUBMISSION_ID}" \
    "${NOTARY_AUTHENTICATION[@]}" \
    "${LOG_PATH}"

[[ "${STATUS}" == "Accepted" ]] || {
    print -u2 -- "notarization was not accepted; review ${LOG_PATH}"
    exit 10
}

/usr/bin/xcrun stapler staple "${APP_PATH}"
/usr/bin/xcrun stapler validate "${APP_PATH}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
/usr/sbin/spctl --assess --type execute --verbose=4 "${APP_PATH}"

/bin/rm -f -- "${ARCHIVE_PATH}"
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr \
    "${APP_PATH}" "${ARCHIVE_PATH}"

readonly ARCHIVE_SHA="$(/usr/bin/shasum -a 256 \
    "${ARCHIVE_PATH}" | /usr/bin/awk '{print $1}')"

/usr/bin/printf \
    'version=%s\nstatus=%s\nsubmission_id=%s\napp=%s\narchive=%s\narchive_sha256=%s\nnotary_log=%s\n' \
    "${VERSION}" \
    "${STATUS}" \
    "${SUBMISSION_ID}" \
    "${APP_PATH}" \
    "${ARCHIVE_PATH}" \
    "${ARCHIVE_SHA}" \
    "${LOG_PATH}"
