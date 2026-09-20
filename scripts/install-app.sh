#!/bin/sh
# Local developer install only; never reset another application's privacy grants.
set -eu

source_app=build/Recorder.app
destination=/Applications/Recorder.app
requirement='identifier "space.microapps.recorder" and certificate leaf[subject.CN] = "Recorder Dev"'
codesign --verify --deep --strict -R="$requirement" "$source_app"
[ ! -L "$destination" ] || { echo "Refusing to replace a symlink: $destination" >&2; exit 1; }

# Copy and verify before touching the installed app; keep replacement on one volume.
stage=$(mktemp -d /Applications/.Recorder-install.XXXXXX)
trap 'rm -rf "$stage"' EXIT
ditto "$source_app" "$stage/Recorder.app"
codesign --verify --deep --strict -R="$requirement" "$stage/Recorder.app"

# NSRunningApplication sends a normal quit, allowing document autosave. Never kill
# a process just because its executable happens to be named Recorder.
osascript -l JavaScript <<'JXA'
ObjC.import('AppKit');
const copies = [];
['space.microapps.recorder', 'sh.nexo.recorder'].forEach(id => {
    const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(id);
    for (let i = 0; i < apps.count; i++) copies.push(apps.objectAtIndex(i));
});
copies.forEach(app => app.terminate);
for (let i = 0; i < 100 && copies.some(app => !app.isTerminated); i++) delay(0.1);
if (copies.some(app => !app.isTerminated)) throw Error('Recorder did not quit. Save your work, quit all copies, then retry make install.');
JXA

if [ -e "$destination" ]; then mv "$destination" "$stage/Previous.app"; fi
if ! mv "$stage/Recorder.app" "$destination"; then
    if [ -e "$stage/Previous.app" ] && ! mv "$stage/Previous.app" "$destination"; then
        trap - EXIT
        echo "Restore failed. Previous app preserved at $stage/Previous.app" >&2
    fi
    exit 1
fi
echo "Installed $destination (Recorder Dev). Existing recordings and settings are untouched."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination"

failed=0
for service in ScreenCapture Accessibility Camera Microphone; do
    if ! tccutil reset "$service" space.microapps.recorder; then failed=1; fi
    # The legacy identity may no longer be registered on a fresh installation.
    if ! tccutil reset "$service" sh.nexo.recorder; then
        echo "Warning: could not reset legacy $service access for sh.nexo.recorder; it may no longer be registered." >&2
    fi
done
if [ "$failed" -ne 0 ]; then
    echo "App installed, but some current Recorder grants could not be reset. Review the errors above." >&2
    exit 1
fi
echo 'Recorder permissions reset. Run: open /Applications/Recorder.app'
echo 'Approve fresh macOS access, then quit and reopen if needed. Self-signing is not Apple notarization or a guarantee of permission detection.'
