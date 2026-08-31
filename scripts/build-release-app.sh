#!/bin/zsh

emulate -L zsh
set -euo pipefail

readonly PROJECT_ROOT="${0:A:h:h}"
readonly VERSION="${1:-0.1.0}"
readonly BUILD_NUMBER="${2:-1}"
readonly SIGNING_IDENTITY="${MEMORY_WATCHER_SIGNING_IDENTITY:--}"

[[ "${VERSION}" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || {
    print -u2 -- "version must use major.minor.patch"
    exit 2
}
[[ "${BUILD_NUMBER}" =~ '^[1-9][0-9]*$' ]] || {
    print -u2 -- "build number must be a positive integer"
    exit 3
}

/usr/bin/swift build \
    --package-path "${PROJECT_ROOT}" \
    --configuration release

readonly BIN_PATH="$(/usr/bin/swift build \
    --package-path "${PROJECT_ROOT}" \
    --configuration release \
    --show-bin-path)"
readonly EXECUTABLE_PATH="${BIN_PATH}/MemoryWatcher"
readonly APP_PATH="${PROJECT_ROOT}/.build/MemoryWatcher-${VERSION}.app"
readonly ARCHIVE_PATH="${PROJECT_ROOT}/.build/MemoryWatcher-${VERSION}.zip"

[[ -x "${EXECUTABLE_PATH}" ]] || {
    print -u2 -- "MemoryWatcher release executable is unavailable"
    exit 4
}
[[ "${APP_PATH}" == "${PROJECT_ROOT}/.build/MemoryWatcher-${VERSION}.app" ]] || {
    print -u2 -- "release app path is outside the fixed build directory"
    exit 5
}
[[ "${ARCHIVE_PATH}" == "${PROJECT_ROOT}/.build/MemoryWatcher-${VERSION}.zip" ]] || {
    print -u2 -- "release archive path is outside the fixed build directory"
    exit 6
}

/bin/mkdir -p "${PROJECT_ROOT}/.build"
readonly STAGING_ROOT="$(/usr/bin/mktemp -d \
    "${PROJECT_ROOT}/.build/MemoryWatcher.release-staging.XXXXXX")"
readonly STAGING_APP="${STAGING_ROOT}/MemoryWatcher-${VERSION}.app"

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
/usr/bin/plutil -insert CFBundleShortVersionString -string "${VERSION}" "${PLIST_PATH}"
/usr/bin/plutil -insert CFBundleVersion -string "${BUILD_NUMBER}" "${PLIST_PATH}"
/usr/bin/plutil -insert LSMinimumSystemVersion -string "14.0" "${PLIST_PATH}"
/usr/bin/plutil -insert NSHighResolutionCapable -bool YES "${PLIST_PATH}"
/usr/bin/plutil -lint "${PLIST_PATH}"

/usr/bin/codesign \
    --force \
    --options runtime \
    --sign "${SIGNING_IDENTITY}" \
    --timestamp=none \
    "${STAGING_APP}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${STAGING_APP}"

if [[ -e "${APP_PATH}" ]]; then
    /bin/rm -rf -- "${APP_PATH}"
fi
if [[ -e "${ARCHIVE_PATH}" ]]; then
    /bin/rm -f -- "${ARCHIVE_PATH}"
fi
/bin/mv "${STAGING_APP}" "${APP_PATH}"
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr \
    "${APP_PATH}" "${ARCHIVE_PATH}"

readonly EXECUTABLE_SHA="$(/usr/bin/shasum -a 256 \
    "${APP_PATH}/Contents/MacOS/MemoryWatcher" | /usr/bin/awk '{print $1}')"
readonly ARCHIVE_SHA="$(/usr/bin/shasum -a 256 \
    "${ARCHIVE_PATH}" | /usr/bin/awk '{print $1}')"

/usr/bin/printf \
    'version=%s\nbuild=%s\napp=%s\narchive=%s\nexecutable_sha256=%s\narchive_sha256=%s\nsigning_identity=%s\n' \
    "${VERSION}" \
    "${BUILD_NUMBER}" \
    "${APP_PATH}" \
    "${ARCHIVE_PATH}" \
    "${EXECUTABLE_SHA}" \
    "${ARCHIVE_SHA}" \
    "${SIGNING_IDENTITY}"
