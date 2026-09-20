#!/bin/sh
# Build arm64 + Intel binaries, merge them, then package a Finder-ready DMG.
set -eu

version="${VERSION:-$(scripts/version.sh version)}"
build="${BUILD:-$(scripts/version.sh build)}"
dist="${DIST:-dist}"
work="$(mktemp -d "${TMPDIR:-/tmp}/recorder-release.XXXXXX")"
trap 'rm -rf "$work"' EXIT HUP INT TERM

printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "Invalid version: $version" >&2; exit 1; }
case "$build" in *[!0-9]*|'') echo "Invalid build number: $build" >&2; exit 1;; esac
if [ -n "${NOTARY_PROFILE:-}" ]; then
    case "${SIGN_ID:--}" in
        'Developer ID Application: '*) ;;
        *) echo "Notarization requires SIGN_ID='Developer ID Application: …'" >&2; exit 1 ;;
    esac
fi

notarize() {
    if [ -n "${NOTARY_KEYCHAIN:-}" ]; then
        xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --keychain "$NOTARY_KEYCHAIN" --wait
    else
        xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
    fi
}

for arch in arm64 x86_64; do
    triple="$arch-apple-macosx15.0"
    scratch="$work/$arch"
    swift build -c release --triple "$triple" --scratch-path "$scratch"
    bin_path="$(swift build -c release --triple "$triple" --scratch-path "$scratch" --show-bin-path)"
    cp "$bin_path/Recorder" "$work/Recorder-$arch"
done
lipo -create "$work/Recorder-arm64" "$work/Recorder-x86_64" -output "$work/Recorder"
lipo "$work/Recorder" -verify_arch arm64 x86_64

mkdir -p "$dist"
app="$work/Recorder.app"
APP="$app" BINARY="$work/Recorder" VERSION="$version" BUILD="$build" SIGN_ID="${SIGN_ID:--}" scripts/assemble-app.sh
codesign --verify --deep --strict --verbose=2 "$app"
if [ -n "${NOTARY_PROFILE:-}" ]; then
    ditto -c -k --keepParent "$app" "$work/Recorder.zip"
    notarize "$work/Recorder.zip"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
fi

stage="$work/dmg-root"
mkdir -p "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
dmg="$dist/Recorder-$version-universal.dmg"
rm -f "$dmg"

if command -v create-dmg >/dev/null 2>&1; then
    create-dmg --volname "Recorder" --volicon Resources/AppIcon.icns --window-size 660 448 --icon-size 96 --text-size 12 \
        --background Resources/DMGBackground.png --icon "Recorder.app" 180 210 \
        --hide-extension "Recorder.app" --app-drop-link 480 210 --no-internet-enable "$dmg" "$stage"
else
    # ponytail: local fallback has no Finder positioning; CI installs create-dmg for the finished layout.
    hdiutil create -volname "Recorder" -srcfolder "$stage" -ov -format UDZO "$dmg"
fi

hdiutil verify "$dmg"
if [ -n "${NOTARY_PROFILE:-}" ]; then
    codesign --sign "$SIGN_ID" --timestamp "$dmg"
    notarize "$dmg"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi
printf '%s\n' "$dmg"
