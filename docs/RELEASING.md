# Releasing Recorder

Push an annotated `vMAJOR.MINOR.PATCH` tag. The release workflow tests the app on
macOS 15, builds arm64 and x86_64 slices, verifies the universal executable, runs
GPU/color and export-sheet checks in the assembled app, then packages and publishes
`Recorder-<version>-universal.dmg`. A failed export check blocks publication.

`make app` derives its version from an exact release tag and its build number from
the commit count or GitHub Actions run number. Untagged builds use `0.0.0`.

## Signing and Gatekeeper

Without Apple credentials, the workflow produces an explicitly labelled ad-hoc
release. It is not notarized, may require **Open Anyway**, and can require permission
grants to be renewed after updates. A local `Recorder Dev` certificate is useful for
development but does not solve public distribution trust.

Configure these repository secrets to enable Developer ID signing and notarization:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application certificate and private key, exported as `.p12`. |
| `APPLE_CERTIFICATE_PASSWORD` | Password protecting the `.p12`. |
| `APPLE_SIGNING_IDENTITY` | Full `Developer ID Application: …` identity name. |
| `APPLE_API_KEY_BASE64` | Base64-encoded App Store Connect API private key (`.p8`). |
| `APPLE_API_KEY_ID` | API key ID. |
| `APPLE_API_ISSUER_ID` | API issuer ID. |

The workflow imports credentials into a temporary keychain, signs with hardened
runtime and camera/microphone entitlements, notarizes and staples both the app and
DMG, checks Gatekeeper assessment, then removes signing material. Incomplete signing
configuration fails instead of silently falling back to an ad-hoc build.

For local distribution, run `scripts/release-dmg.sh` with `VERSION`, `SIGN_ID` and
`NOTARY_PROFILE` (a stored `notarytool` profile), plus optional `NOTARY_KEYCHAIN`.
Install `create-dmg` for the styled Finder layout. Without it, local packaging uses
a plain `hdiutil` image.

See [Apple’s notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Graphics and screenshots

```sh
swift scripts/render-brand-assets.swift
swift scripts/render-readme-graphics.swift
make app
build/Recorder.app/Contents/MacOS/Recorder --selftest editor-review-png build/readme-editor --readme
build/Recorder.app/Contents/MacOS/Recorder --selftest capture-panel-png build/readme-capture.png
```

README images live in `docs/images/`. The editor screenshot is the production
window with generated demo media, not a mockup. Inspect rendered images before
updating the checked-in screenshots; never publish private recording content.
