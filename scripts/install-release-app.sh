#!/bin/zsh

emulate -L zsh
set -euo pipefail

readonly PROJECT_ROOT="${0:A:h:h}"
readonly VERSION="${1:-0.1.0}"
readonly SOURCE_APP="${PROJECT_ROOT}/.build/MemoryWatcher-${VERSION}.app"
readonly TARGET_APP="/Applications/Memory Watcher.app"

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
    print -u2 -- "installed app differs; refusing to overwrite it"
    exit 6
fi

/usr/bin/ditto "${SOURCE_APP}" "${TARGET_APP}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${TARGET_APP}"
/usr/bin/cmp \
    "${SOURCE_APP}/Contents/MacOS/MemoryWatcher" \
    "${TARGET_APP}/Contents/MacOS/MemoryWatcher"
/usr/bin/plutil -lint "${TARGET_APP}/Contents/Info.plist"
print -r -- "${TARGET_APP}"
