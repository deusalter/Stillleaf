#!/bin/zsh
# Developer ID signing with the hardened runtime and a secure timestamp.
#
#   STILLLEAF_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/release/sign-app.sh Stillleaf.app
#
# Optional: STILLLEAF_KEYCHAIN selects a keychain (CI imports the certificate into a temporary one).
# Code is signed inside-out, one item at a time; `codesign --deep` is not used for signing.
set -euo pipefail

root_dir=${0:A:h:h:h}
app=${1:?usage: sign-app.sh Stillleaf.app}
identity=${STILLLEAF_SIGN_IDENTITY:?Set STILLLEAF_SIGN_IDENTITY to a Developer ID Application identity}
entitlements="$root_dir/assets/Stillleaf.entitlements"
[[ "$identity" == "Developer ID Application:"* || "$identity" =~ '^[0-9A-F]{40}$' ]] || {
  print -u2 "STILLLEAF_SIGN_IDENTITY must be a Developer ID Application identity or its SHA-1 hash"; exit 1
}

options=(--force --timestamp --options runtime --sign "$identity")
[[ -n "${STILLLEAF_KEYCHAIN:-}" ]] && options+=(--keychain "$STILLLEAF_KEYCHAIN")
bundle_id=$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")

for library in "$app"/Contents/Frameworks/*.dylib; do
  codesign $options "$library"
done
codesign $options --identifier "$bundle_id.books-diagnostic" --entitlements "$entitlements" "$app/Contents/MacOS/books-diagnostic"
# Signing the bundle signs its main executable and seals Resources (reader, notices, icon).
codesign $options --entitlements "$entitlements" "$app"

codesign --verify --strict --deep --verbose=2 "$app"
print "Signed $app with $identity"
