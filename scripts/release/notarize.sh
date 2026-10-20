#!/bin/zsh
# Submit an app or disk image to Apple's notary service, wait, then staple the ticket.
#
#   scripts/release/notarize.sh Stillleaf.app   # zipped for upload; the ticket is stapled to the app
#   scripts/release/notarize.sh Stillleaf.dmg
#
# Credentials come from the environment only, in this order:
#   STILLLEAF_NOTARY_PROFILE   keychain profile created with `xcrun notarytool store-credentials`
#   STILLLEAF_NOTARY_KEY_PATH + STILLLEAF_NOTARY_KEY_ID + STILLLEAF_NOTARY_ISSUER
#                              App Store Connect API key (.p8), as used by the release workflow
# STILLLEAF_NOTARY_LOG_DIR keeps the notary JSON log next to the release artifacts.
set -euo pipefail

target=${1:?usage: notarize.sh Stillleaf.app|Stillleaf.dmg}
log_dir=${STILLLEAF_NOTARY_LOG_DIR:-${TMPDIR:-/tmp}}
mkdir -p "$log_dir"

if [[ -n "${STILLLEAF_NOTARY_PROFILE:-}" ]]; then
  auth=(--keychain-profile "$STILLLEAF_NOTARY_PROFILE")
elif [[ -n "${STILLLEAF_NOTARY_KEY_PATH:-}" && -n "${STILLLEAF_NOTARY_KEY_ID:-}" && -n "${STILLLEAF_NOTARY_ISSUER:-}" ]]; then
  auth=(--key "$STILLLEAF_NOTARY_KEY_PATH" --key-id "$STILLLEAF_NOTARY_KEY_ID" --issuer "$STILLLEAF_NOTARY_ISSUER")
else
  print -u2 "No notarization credentials: set STILLLEAF_NOTARY_PROFILE, or STILLLEAF_NOTARY_KEY_PATH/KEY_ID/ISSUER."
  exit 2
fi

upload=$target
if [[ "$target" == *.app ]]; then
  upload="${TMPDIR:-/tmp}/${target:t:r}-notarize-$$.zip"
  ditto -c -k --sequesterRsrc --keepParent "$target" "$upload"
fi

name=${target:t}
result="$log_dir/notary-$name.json"
xcrun notarytool submit "$upload" $auth --wait --timeout 1h --output-format json > "$result"
[[ "$upload" != "$target" ]] && rm -f "$upload"
read -r submission state <<<"$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r.get("id",""), r.get("status",""))' "$result")"
# The log lists every issue, including warnings on accepted submissions; keep it either way.
[[ -n "$submission" ]] && xcrun notarytool log "$submission" $auth "$log_dir/notary-$name-log.json" >/dev/null || true
if [[ "$state" != Accepted ]]; then
  print -u2 "Notarization of $name finished as '$state' (submission $submission). See $log_dir/notary-$name-log.json"
  exit 1
fi

xcrun stapler staple "$target"
xcrun stapler validate "$target"
print "Notarized and stapled $name (submission $submission)"
