#!/bin/zsh

emulate -L zsh
set -euo pipefail

readonly PROJECT_ROOT="${0:A:h:h}"
readonly CONFIGURATION="${1:-debug}"

if [[ "${CONFIGURATION}" != "debug" && "${CONFIGURATION}" != "release" ]]; then
    print -u2 -- "configuration must be debug or release"
    exit 2
fi

/usr/bin/swift build \
    --package-path "${PROJECT_ROOT}" \
    --configuration "${CONFIGURATION}"

readonly BIN_PATH="$(/usr/bin/swift build \
    --package-path "${PROJECT_ROOT}" \
    --configuration "${CONFIGURATION}" \
    --show-bin-path)"
readonly EXECUTABLE_PATH="${BIN_PATH}/MemoryWatcher"
readonly APP_PATH="${PROJECT_ROOT}/.build/MemoryWatcher.app"

[[ -x "${EXECUTABLE_PATH}" ]] || {
    print -u2 -- "MemoryWatcher executable is unavailable"
    exit 3
}
[[ "${APP_PATH}" == "${PROJECT_ROOT}/.build/MemoryWatcher.app" ]] || {
    print -u2 -- "development app path is outside the fixed build directory"
    exit 4
}

/bin/mkdir -p "${PROJECT_ROOT}/.build"
readonly STAGING_ROOT="$(/usr/bin/mktemp -d \
    "${PROJECT_ROOT}/.build/MemoryWatcher.staging.XXXXXX")"
readonly STAGING_APP="${STAGING_ROOT}/MemoryWatcher.app"

cleanup() {
    [[ -d "${STAGING_ROOT}" ]] && /bin/rm -rf -- "${STAGING_ROOT}"
}
trap cleanup EXIT

/bin/mkdir -p "${STAGING_APP}/Contents/MacOS"
/bin/mkdir -p "${STAGING_APP}/Contents/Resources"
/bin/cp "${EXECUTABLE_PATH}" "${STAGING_APP}/Contents/MacOS/MemoryWatcher"
/bin/chmod 0755 "${STAGING_APP}/Contents/MacOS/MemoryWatcher"

readonly PLIST_PATH="${STAGING_APP}/Contents/Info.plist"
/usr/bin/plutil -create xml1 "${PLIST_PATH}"
/usr/bin/plutil -insert CFBundleDevelopmentRegion -string "en" "${PLIST_PATH}"
/usr/bin/plutil -insert CFBundleDisplayName -string "Memory Watcher" "${PLIST_PATH}"
/usr/bin/plutil -insert CFBundleExecutable -string "MemoryWatcher" "${PLIST_PATH}"
/usr/bin/plutil -insert CFBundleIdentifier -string "com.oneroad.memorywatcher" "${PLIST_PATH}"
/usr/bin/plutil -insert CFBundleInfoDictionaryVersion -string "6.0" "${PLIST_PATH}"
/usr/bin/plutil -insert CFBundleName -string "Memory Watcher" "${PLIST_PATH}"
/usr/bin/plutil -insert CFBundlePackageType -string "APPL" "${PLIST_PATH}"
/usr/bin/plutil -insert CFBundleShortVersionString -string "0.1.0-dev" "${PLIST_PATH}"
/usr/bin/plutil -insert CFBundleVersion -string "1" "${PLIST_PATH}"
/usr/bin/plutil -insert LSMinimumSystemVersion -string "14.0" "${PLIST_PATH}"
/usr/bin/plutil -insert NSHighResolutionCapable -bool YES "${PLIST_PATH}"
/usr/bin/plutil -lint "${PLIST_PATH}"

/usr/bin/codesign \
    --force \
    --sign - \
    --timestamp=none \
    "${STAGING_APP}"

if [[ -e "${APP_PATH}" ]]; then
    /bin/rm -rf -- "${APP_PATH}"
fi
/bin/mv "${STAGING_APP}" "${APP_PATH}"

print -r -- "${APP_PATH}"
