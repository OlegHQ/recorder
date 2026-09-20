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
launch: System Settings → Privacy & Security → Open Anyway. Copy the app to
Applications before granting permissions. After replacing an ad-hoc build,
macOS may retain enabled entries for the old app: remove Recorder from Screen
Recording and Accessibility, add the installed app again, then use **Check again**.

For releases without the Gatekeeper override, configure these repository secrets:
`APPLE_CERTIFICATE_BASE64` (Developer ID Application .p12), `APPLE_CERTIFICATE_PASSWORD`,
`APPLE_SIGNING_IDENTITY`, `APPLE_API_KEY_BASE64` (.p8), `APPLE_API_KEY_ID`, and
`APPLE_API_ISSUER_ID`. The workflow signs, notarizes and staples both the app and DMG.
Partial signing configuration fails the build; absent credentials retain the explicitly
labelled ad-hoc release. Local releases accept `SIGN_ID` and `NOTARY_PROFILE`
(a `notarytool` keychain profile), plus optional `NOTARY_KEYCHAIN`.

Regenerate the icon and installer artwork with `swift scripts/render-brand-assets.swift`.

The app requires macOS 15 or later. Font notices are in
`Resources/THIRD_PARTY_NOTICES.md`; the source is MIT licensed.
