# Recorder

Native macOS screen recording and non-destructive editing. Created by Oleg
Pustovit.

## Build

```sh
make app
make test
```

`make app` derives its marketing version from an exact `vMAJOR.MINOR.PATCH`
tag and its build number from the Git commit count (or GitHub Actions run
number). It never ships the template values in `Resources/Info.plist`.

## Release

Push an annotated tag such as `v0.1.0`. The release workflow tests the app,
builds arm64 and x86_64 slices, verifies the universal executable, and
publishes `Recorder-0.1.0-universal.dmg` to that GitHub release. It is ad-hoc
signed but not notarized, so macOS may require users to approve it on first
launch.

The app requires macOS 15 or later. Font notices are in
`Resources/THIRD_PARTY_NOTICES.md`; the source is MIT licensed.
