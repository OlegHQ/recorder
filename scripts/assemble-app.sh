#!/bin/sh
# Assemble the SwiftPM executable and loose resources into a distributable app bundle.
set -eu

app="${APP:-build/Recorder.app}"
binary="${BINARY:?BINARY must name the compiled Recorder executable}"
version="${VERSION:-$(scripts/version.sh version)}"
build="${BUILD:-$(scripts/version.sh build)}"
sign_id="${SIGN_ID:--}"

[ -x "$binary" ] || { echo "Missing executable: $binary" >&2; exit 1; }
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "Invalid version: $version" >&2; exit 1; }
case "$build" in *[!0-9]*|'') echo "Invalid build number: $build" >&2; exit 1;; esac

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Recorder"
cp Resources/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build" "$app/Contents/Info.plist"
cp -R Resources/Fonts Resources/Wallpapers "$app/Contents/Resources/"
cp Resources/AppIcon.icns Resources/click.caf Resources/THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"

if [ "$sign_id" = "-" ]; then
    codesign --force --sign - "$app"
else
    codesign --force --options runtime --timestamp --sign "$sign_id" "$app"
fi
