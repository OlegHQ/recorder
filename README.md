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
builds arm64 and x86_64 slices, verifies the universal executable, signs and
notarizes it, then publishes `Recorder-0.1.0-universal.dmg` to that GitHub
release. Before tagging, configure these repository secrets: the Developer ID
certificate as `APPLE_CERTIFICATE_BASE64`, its password as
`APPLE_CERTIFICATE_PASSWORD`, the certificate name as `APPLE_SIGNING_IDENTITY`,
and the App Store Connect API key as `APPLE_API_KEY_BASE64`,
`APPLE_API_KEY_ID`, and `APPLE_API_ISSUER_ID`.

The app requires macOS 15 or later. Font notices are in
`Resources/THIRD_PARTY_NOTICES.md`; the source is MIT licensed.
