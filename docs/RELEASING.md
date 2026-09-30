# Releasing Recorder

Push an annotated `vMAJOR.MINOR.PATCH` tag. The release workflow tests the app on
macOS 15, builds arm64 and x86_64 slices, verifies the universal executable, runs
GPU/color and export-sheet checks in the assembled app, then packages and publishes
`Recorder-<version>-universal.dmg`. A failed export check blocks publication.

`make app` derives its version from an exact release tag and its build number from
the commit count or GitHub Actions run number. Untagged builds use `0.0.0`.

## Signing and Gatekeeper

The release workflow requires Apple credentials. Missing or invalid credentials stop
publication; `Recorder Dev` is useful locally but is not trusted for distribution.
Existing releases built before this change remain ad-hoc signed.

The Apple ID for notarization must belong to an active Apple Developer Program
team. Configure these GitHub repository secrets:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application certificate and private key, exported as `.p12`. |
| `APPLE_CERTIFICATE_PASSWORD` | Password protecting the `.p12`. |
| `APPLE_SIGNING_IDENTITY` | Full `Developer ID Application: …` identity name. |
| `APPLE_ID` | Apple Account email used for notarization. |
| `APPLE_TEAM_ID` | The 10-character Team ID shown in Apple Developer account Membership details. |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password generated for this Apple ID at account.apple.com. |

On a Mac with the Developer ID Application certificate and its private key in
Keychain Access, export both as a password-protected `.p12`. Check that
`security find-identity -v -p codesigning` lists its full identity. Then set the
secrets from a terminal without putting their values in shell history:

```sh
gh secret set APPLE_CERTIFICATE_BASE64 --repo OlegHQ/recorder < <(base64 < /path/to/DeveloperID.p12)
gh secret set APPLE_CERTIFICATE_PASSWORD --repo OlegHQ/recorder
gh secret set APPLE_SIGNING_IDENTITY --repo OlegHQ/recorder
gh secret set APPLE_ID --repo OlegHQ/recorder
gh secret set APPLE_TEAM_ID --repo OlegHQ/recorder
gh secret set APPLE_APP_SPECIFIC_PASSWORD --repo OlegHQ/recorder
```

Each `gh secret set` without redirected input prompts for the value. The first
command uses zsh/bash process substitution; replace `/path/to/DeveloperID.p12` with
the exported file. Never commit or paste the `.p12`, its password, or the app-specific
password into an issue or chat. Confirm secret names with
`gh secret list --repo OlegHQ/recorder`, then push a new version tag and check the
Release workflow. After it succeeds, download the DMG and verify it on a separate
Mac or user account before changing the installation guidance.

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
