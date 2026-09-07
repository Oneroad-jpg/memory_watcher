#!/bin/zsh

emulate -L zsh
set -euo pipefail

readonly PROJECT_ROOT="${0:A:h:h}"
readonly VERSION="${1:-0.1.0}"
readonly SOURCE_APP="${PROJECT_ROOT}/.build/MemoryWatcher-${VERSION}.app"
readonly TARGET_APP="/Applications/Memory Watcher.app"
readonly ALLOW_UPGRADE="${MEMORY_WATCHER_ALLOW_UPGRADE:-0}"
readonly BACKUP_ROOT="${PROJECT_ROOT}/.build/installed-app-backups"

typeset BACKUP_APP=""
typeset FAILED_APP="${BACKUP_ROOT}/MemoryWatcher-${VERSION}-failed.app"
typeset INSTALL_STARTED=0

verify_distribution() {
    local app_path="$1"
    local signing_details

    /usr/bin/codesign --verify --deep --strict --verbose=2 "${app_path}"
    signing_details="$(/usr/bin/codesign \
        --display \
        --verbose=4 \
        "${app_path}" 2>&1)"

    if [[ "${signing_details}" == *"Authority=Developer ID Application:"* ]]; then
        [[ "${signing_details}" == *"Runtime Version="* ]] || {
            print -u2 -- "Developer ID app does not declare hardened runtime"
            return 1
        }
        [[ "${signing_details}" == *"Timestamp="* ]] || {
            print -u2 -- "Developer ID app does not contain a secure timestamp"
            return 1
        }
        /usr/bin/xcrun stapler validate "${app_path}"
        /usr/sbin/spctl --assess --type execute --verbose=4 "${app_path}"
    fi
}

restore_previous_install() {
    local exit_code=$?
    trap - EXIT

    if (( exit_code != 0 && INSTALL_STARTED == 1 )); then
        if [[ -e "${TARGET_APP}" && ! -e "${FAILED_APP}" ]]; then
            /bin/mv "${TARGET_APP}" "${FAILED_APP}" || true
        fi
        if [[ -n "${BACKUP_APP}" && -e "${BACKUP_APP}" \
            && ! -e "${TARGET_APP}" ]]
        then
            /bin/mv "${BACKUP_APP}" "${TARGET_APP}" || true
            print -u2 -- "installation failed; restored the previous app"
        fi
    fi

    exit "${exit_code}"
}

trap restore_previous_install EXIT

[[ "${VERSION}" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || {
    print -u2 -- "version must use major.minor.patch"
    exit 2
}
[[ -d "${SOURCE_APP}" ]] || {
    print -u2 -- "release app is unavailable: run build-release-app.sh first"
    exit 3
}
/usr/bin/codesign --verify --deep --strict --verbose=2 "${SOURCE_APP}"

readonly SOURCE_VERSION="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "${SOURCE_APP}/Contents/Info.plist")"
readonly SOURCE_BUNDLE_ID="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIdentifier' \
    "${SOURCE_APP}/Contents/Info.plist")"
[[ "${SOURCE_VERSION}" == "${VERSION}" ]] || {
    print -u2 -- "release app version does not match the requested version"
    exit 4
}
[[ "${SOURCE_BUNDLE_ID}" == "com.oneroad.memorywatcher" ]] || {
    print -u2 -- "release app bundle identifier is unexpected"
    exit 5
}
verify_distribution "${SOURCE_APP}"

if [[ -e "${TARGET_APP}" ]]; then
    /usr/bin/codesign --verify --deep --strict --verbose=2 "${TARGET_APP}"
    if /usr/bin/cmp -s \
        "${SOURCE_APP}/Contents/MacOS/MemoryWatcher" \
        "${TARGET_APP}/Contents/MacOS/MemoryWatcher" \
        && /usr/bin/cmp -s \
            "${SOURCE_APP}/Contents/Info.plist" \
            "${TARGET_APP}/Contents/Info.plist" \
        && /usr/bin/cmp -s \
            "${SOURCE_APP}/Contents/_CodeSignature/CodeResources" \
            "${TARGET_APP}/Contents/_CodeSignature/CodeResources"
    then
        print -r -- "${TARGET_APP}"
        exit 0
    fi

    [[ "${ALLOW_UPGRADE}" == "1" ]] || {
        print -u2 -- \
            "installed app differs; set MEMORY_WATCHER_ALLOW_UPGRADE=1 to preserve and replace it"
        exit 6
    }
    /usr/bin/pgrep -x MemoryWatcher > /dev/null && {
        print -u2 -- "Memory Watcher is running; quit it before upgrading"
        exit 7
    }

    readonly TARGET_VERSION="$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleShortVersionString' \
        "${TARGET_APP}/Contents/Info.plist")"
    readonly TARGET_BUNDLE_ID="$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleIdentifier' \
        "${TARGET_APP}/Contents/Info.plist")"
    [[ "${TARGET_BUNDLE_ID}" == "${SOURCE_BUNDLE_ID}" ]] || {
        print -u2 -- "installed app bundle identifier is unexpected"
        exit 8
    }

    BACKUP_APP="${BACKUP_ROOT}/MemoryWatcher-${TARGET_VERSION}-before-${VERSION}.app"
    [[ ! -e "${BACKUP_APP}" ]] || {
        print -u2 -- "upgrade backup already exists; refusing to replace it"
        exit 9
    }
fi

[[ ! -e "${FAILED_APP}" ]] || {
    print -u2 -- "failed-install evidence already exists; inspect it before retrying"
    exit 10
}
/bin/mkdir -p "${BACKUP_ROOT}"
if [[ -n "${BACKUP_APP}" ]]; then
    /bin/mv "${TARGET_APP}" "${BACKUP_APP}"
fi
INSTALL_STARTED=1
/usr/bin/ditto "${SOURCE_APP}" "${TARGET_APP}"
verify_distribution "${TARGET_APP}"
/usr/bin/cmp \
    "${SOURCE_APP}/Contents/MacOS/MemoryWatcher" \
    "${TARGET_APP}/Contents/MacOS/MemoryWatcher"
/usr/bin/cmp \
    "${SOURCE_APP}/Contents/Info.plist" \
    "${TARGET_APP}/Contents/Info.plist"
/usr/bin/cmp \
    "${SOURCE_APP}/Contents/_CodeSignature/CodeResources" \
    "${TARGET_APP}/Contents/_CodeSignature/CodeResources"
/usr/bin/plutil -lint "${TARGET_APP}/Contents/Info.plist"
INSTALL_STARTED=0
trap - EXIT
if [[ -n "${BACKUP_APP}" ]]; then
    print -r -- "backup=${BACKUP_APP}"
fi
print -r -- "${TARGET_APP}"
