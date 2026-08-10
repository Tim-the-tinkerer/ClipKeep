#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

LAUNCH=true
for arg in "$@"; do
    case "${arg}" in
        --no-launch) LAUNCH=false ;;
    esac
done

APP="ClipKeep.app"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -f Assets/AppIcon.icns ]]; then
    echo "Generating app icon..."
    swift Scripts/GenerateAppIcon.swift
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' AppInfo.plist 2>/dev/null || echo unknown)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' AppInfo.plist 2>/dev/null || echo unknown)"
echo "Building ClipKeep ${VERSION} (build ${BUILD}, release)..."
swift build -c release

echo "Assembling ${APP}..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"
cp .build/release/ClipKeep "${APP}/Contents/MacOS/ClipKeep"
chmod +x "${APP}/Contents/MacOS/ClipKeep"
cp AppInfo.plist "${APP}/Contents/Info.plist"

if [[ -f Assets/AppIcon.icns ]]; then
    cp Assets/AppIcon.icns "${APP}/Contents/Resources/"
fi

echo "Signing ${APP}..."
xattr -cr "${APP}" 2>/dev/null || true
codesign --force --sign - --timestamp=none "${APP}/Contents/MacOS/ClipKeep"
codesign --force --sign - --timestamp=none "${APP}"

echo "Done: ${APP} (v${VERSION} build ${BUILD})"
if [[ "${LAUNCH}" == "true" ]]; then
    echo "Launching..."
    open "${APP}"
fi
