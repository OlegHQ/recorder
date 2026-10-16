#!/bin/sh
# Imports the Developer ID identity from .apple (gitignored 1Password JSON export) into recorder-signing.keychain.
# Empty keychain password so `make` can unlock it over SSH, where the login keychain stays locked.
set -eu
umask 077

kc="$HOME/Library/Keychains/recorder-signing.keychain-db"
[ -f .apple ] || { echo "Missing .apple (1Password export with APPLE_CERTIFICATE_BASE64)" >&2; exit 1; }
[ -e "$kc" ] || security create-keychain -p "" "$kc"
security set-keychain-settings "$kc"
security unlock-keychain -p "" "$kc"

if ! security find-identity -v -p codesigning "$kc" | grep -q "Developer ID Application"; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    /usr/bin/python3 -I - .apple "$tmp/id.p12" "$tmp/pw" <<'EOF'
import base64, json, sys
item = json.load(open(sys.argv[1]))
fields = {f["t"]: f["v"] for section in item["details"]["sections"] for f in section["fields"]}
open(sys.argv[2], "wb").write(base64.b64decode(fields["APPLE_CERTIFICATE_BASE64"]))
open(sys.argv[3], "w").write(fields["Certificate password"])
EOF
    security import "$tmp/id.p12" -k "$kc" -P "$(cat "$tmp/pw")" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$kc" >/dev/null
fi

# Keep the user's existing keychains in the search list; add ours once.
if ! security list-keychains -d user | grep -q recorder-signing; then
    eval "set -- $(security list-keychains -d user | tr '\n' ' ')"
    security list-keychains -d user -s "$@" "$kc"
fi
security find-identity -v -p codesigning | grep "Developer ID Application"
