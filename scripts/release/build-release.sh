#!/bin/zsh
# Build a public Stillleaf release: universal app, Developer ID signature with the hardened
# runtime, notarized and stapled app and disk image, checksums and the update feed.
# docs/RELEASE_CHECKLIST.md is the human procedure around this script.
#
# Environment (credentials only ever come from here, a keychain profile or CI secrets):
#   STILLLEAF_SIGN_IDENTITY       "Developer ID Application: Name (TEAMID)". Without it the
#                                 result is an ad-hoc signed preview that is not for distribution.
#   STILLLEAF_KEYCHAIN            optional keychain holding that identity
#   STILLLEAF_NOTARY_PROFILE      notarytool keychain profile, or the STILLLEAF_NOTARY_KEY_* trio
#   STILLLEAF_REQUIRE_NOTARIZATION=1  fail instead of skipping when notarization is impossible
#   STILLLEAF_UPDATE_FEED_URL     https URL the app checks, e.g. https://HOST/updates/macos.json
#   STILLLEAF_DOWNLOAD_BASE_URL   https URL the disk image is published under, e.g. https://HOST/download
#   STILLLEAF_RELEASE_NOTES_URL   optional; "{version}" is replaced, e.g. https://HOST/releases/{version}
#   STILLLEAF_RELEASE_TAG         optional; must equal v<CFBundleShortVersionString> (CI passes the tag)
#   STILLLEAF_ALLOW_DIRTY=1       allow uncommitted changes (never for a published release)
set -euo pipefail

root_dir=${0:A:h:h:h}
cd "$root_dir"
release=$root_dir/scripts/release
version=$(plutil -extract CFBundleShortVersionString raw assets/Info.plist)
build=${STILLLEAF_BUILD_NUMBER:-$(git rev-list --count HEAD)}
export STILLLEAF_BUILD_NUMBER=$build

if [[ "${STILLLEAF_ALLOW_DIRTY:-0}" != 1 && -n "$(git status --porcelain --untracked-files=no)" ]]; then
  print -u2 "Uncommitted changes: a release must be built from a commit. Set STILLLEAF_ALLOW_DIRTY=1 for a dry run."
  exit 1
fi
if [[ -n "${STILLLEAF_RELEASE_TAG:-}" && "$STILLLEAF_RELEASE_TAG" != "v$version" ]]; then
  print -u2 "Tag $STILLLEAF_RELEASE_TAG does not match assets/Info.plist version $version (expected v$version)."
  exit 1
fi

level=adhoc
[[ -n "${STILLLEAF_SIGN_IDENTITY:-}" ]] && level=signed
can_notarize=0
[[ -n "${STILLLEAF_NOTARY_PROFILE:-}" || ( -n "${STILLLEAF_NOTARY_KEY_PATH:-}" && -n "${STILLLEAF_NOTARY_KEY_ID:-}" && -n "${STILLLEAF_NOTARY_ISSUER:-}" ) ]] && can_notarize=1
if [[ $level == signed && $can_notarize == 1 ]]; then level=notarized; fi
if [[ "${STILLLEAF_REQUIRE_NOTARIZATION:-0}" == 1 && $level != notarized ]]; then
  print -u2 "Notarization required, but the signing identity or notary credentials are missing."
  exit 1
fi

suffix=""; [[ $level != notarized ]] && suffix="-$level"
out=$root_dir/.build/release-artifacts/$version-$build
rm -rf "$out"; mkdir -p "$out/logs"
work=$out/package
print "== Stillleaf $version ($build): building a universal app ($level)"
STILLLEAF_UNIVERSAL=1 STILLLEAF_DIST_DIR=$work "$root_dir/scripts/package-app.sh"
app=$work/Stillleaf.app
rm -f "$work"/Stillleaf-*.zip   # the development archive; release archives are made below

if [[ $level != adhoc ]]; then
  print "== Signing with the hardened runtime"
  "$release/sign-app.sh" "$app"
  python3 "$release/verify-release.py" "$app" --level signed
fi
if [[ $level == notarized ]]; then
  print "== Notarizing the app"
  STILLLEAF_NOTARY_LOG_DIR=$out/logs "$release/notarize.sh" "$app"
fi

dmg=$out/Stillleaf-$version$suffix.dmg
zip=$out/Stillleaf-$version$suffix.zip
print "== Packaging"
"$release/make-dmg.sh" "$app" "$dmg"
if [[ $level == notarized ]]; then
  print "== Notarizing the disk image"
  STILLLEAF_NOTARY_LOG_DIR=$out/logs "$release/notarize.sh" "$dmg"
fi
# The zip holds the stapled app, for people who prefer it to a disk image.
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

print "== Verifying ($level)"
python3 "$release/verify-release.py" "$app" "$dmg" --level $level | tee "$out/logs/verify.txt"
(cd "$out" && shasum -a 256 "${dmg:t}" "${zip:t}" > SHA256SUMS)

if [[ -n "${STILLLEAF_DOWNLOAD_BASE_URL:-}" ]]; then
  notes=()
  [[ -n "${STILLLEAF_RELEASE_NOTES_URL:-}" ]] && notes=(--notes-url "${STILLLEAF_RELEASE_NOTES_URL//\{version\}/$version}")
  python3 "$release/make-update-feed.py" --app "$app" --artifact "$dmg" \
    --download-url "${STILLLEAF_DOWNLOAD_BASE_URL%/}/${dmg:t}" $notes --output-dir "$out"
fi

print "\nRelease artifacts in $out:"
ls -1 "$out"
case $level in
  notarized) print "\nNotarized and stapled. Follow docs/RELEASE_CHECKLIST.md before publishing." ;;
  signed) print "\nSigned but NOT notarized: Gatekeeper will block this download. Do not publish it." ;;
  adhoc) print "\nAd-hoc preview: no Developer ID signature. Do not publish it." ;;
esac
