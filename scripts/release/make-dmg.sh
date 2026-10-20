#!/bin/zsh
# Build a compressed, read-only disk image holding Stillleaf.app and an Applications shortcut.
#
#   scripts/release/make-dmg.sh Stillleaf.app Stillleaf-1.5.0.dmg
#
# When STILLLEAF_SIGN_IDENTITY is set the image itself is signed too (Gatekeeper checks the
# image's signature when it is opened); notarize and staple it afterwards with notarize.sh.
set -euo pipefail

app=${1:?usage: make-dmg.sh Stillleaf.app output.dmg}
output=${2:?usage: make-dmg.sh Stillleaf.app output.dmg}
[[ -d "$app/Contents" ]] || { print -u2 "$app is not an app bundle"; exit 1; }

staging=$(mktemp -d "${TMPDIR:-/tmp}/stillleaf-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
# ditto keeps the code signature, stapled ticket and extended attributes intact.
ditto "$app" "$staging/${app:t}"
ln -s /Applications "$staging/Applications"

rm -f "$output"
hdiutil create -quiet -volname Stillleaf -srcfolder "$staging" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$output"

if [[ -n "${STILLLEAF_SIGN_IDENTITY:-}" ]]; then
  options=(--force --timestamp --sign "$STILLLEAF_SIGN_IDENTITY")
  [[ -n "${STILLLEAF_KEYCHAIN:-}" ]] && options+=(--keychain "$STILLLEAF_KEYCHAIN")
  codesign $options "$output"
  codesign --verify --strict --verbose=2 "$output"
fi
hdiutil verify -quiet "$output"
print "Created $output"
