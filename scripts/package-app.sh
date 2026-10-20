#!/bin/zsh
set -euo pipefail

root_dir=${0:A:h:h}
dist_dir="${STILLLEAF_DIST_DIR:-$root_dir/dist}"
app_dir="$dist_dir/Stillleaf.app"
binary_dir="$root_dir/.build/local"

if [[ ! -x "$root_dir/scripts/build-local.sh" ]]; then
  print -u2 "Missing scripts/build-local.sh. Build with a full Xcode toolchain using: swift build -c release"
  exit 1
fi

binaries=(BooksPresence books-diagnostic libBooksCore.dylib libBooksPlatform.dylib)
architectures=("$(uname -m)")

"$root_dir/scripts/generate-pageleaf.sh"
if [[ "${STILLLEAF_UNIVERSAL:-0}" == "1" ]]; then
  # Public releases run on Apple silicon and Intel Macs. Build each slice separately with the
  # same direct compiler path, build the architecture-independent reader once, then lipo.
  architectures=(arm64 x86_64)
  binary_dir="$root_dir/.build/local-universal"
  rm -rf "$binary_dir"; mkdir -p "$binary_dir"
  for arch in $architectures; do
    skip_reader=1; [[ "$arch" == arm64 ]] && skip_reader=0
    BOOKSPRESENCE_ARCH=$arch BOOKSPRESENCE_BUILD_DIR="$root_dir/.build/local-$arch" BOOKSPRESENCE_SKIP_READER_BUILD=$skip_reader "$root_dir/scripts/build-local.sh"
  done
  for binary in $binaries; do
    lipo -create "$root_dir/.build/local-arm64/$binary" "$root_dir/.build/local-x86_64/$binary" -output "$binary_dir/$binary"
  done
  cp -R "$root_dir/.build/local-arm64/Reader" "$binary_dir/Reader"
else
  "$root_dir/scripts/build-local.sh"
fi

if [[ ! -x "$binary_dir/BooksPresence" || ! -x "$binary_dir/books-diagnostic" ]]; then
  print -u2 "Local build did not produce BooksPresence and books-diagnostic in $binary_dir"
  exit 1
fi

# The marketing version lives in assets/Info.plist. The build number is the commit count, so the
# same commit always gets the same number and later main commits always compare newer. A
# `git archive` export has no history and keeps the committed number unless one is supplied.
build_number=${STILLLEAF_BUILD_NUMBER:-}
if [[ -z "$build_number" ]] && git -C "$root_dir" rev-parse --git-dir >/dev/null 2>&1; then
  build_number=$(git -C "$root_dir" rev-list --count HEAD)
fi

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Frameworks"
cp "$root_dir/assets/Info.plist" "$app_dir/Contents/Info.plist"
info="$app_dir/Contents/Info.plist"
[[ -n "$build_number" ]] && plutil -replace CFBundleVersion -string "$build_number" "$info"
if [[ -n "${STILLLEAF_UPDATE_FEED_URL:-}" ]]; then
  [[ "$STILLLEAF_UPDATE_FEED_URL" == https://* ]] || { print -u2 "STILLLEAF_UPDATE_FEED_URL must be an https URL"; exit 1; }
  plutil -insert StillleafUpdateFeedURL -string "$STILLLEAF_UPDATE_FEED_URL" "$info"
fi
cp "$root_dir/THIRD_PARTY_NOTICES.md" "$app_dir/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$root_dir/assets/BooksPresence.icns" "$app_dir/Contents/Resources/BooksPresence.icns"
cp -R "$binary_dir/Reader" "$app_dir/Contents/Resources/Reader"
cp "$binary_dir/BooksPresence" "$app_dir/Contents/MacOS/BooksPresence"
cp "$binary_dir/books-diagnostic" "$app_dir/Contents/MacOS/books-diagnostic"
cp "$binary_dir/libBooksCore.dylib" "$app_dir/Contents/Frameworks/libBooksCore.dylib"
cp "$binary_dir/libBooksPlatform.dylib" "$app_dir/Contents/Frameworks/libBooksPlatform.dylib"
codesign --force --sign - --timestamp=none "$app_dir/Contents/Frameworks/libBooksCore.dylib"
codesign --force --sign - --timestamp=none "$app_dir/Contents/Frameworks/libBooksPlatform.dylib"
codesign --force --sign - --timestamp=none "$app_dir/Contents/MacOS/books-diagnostic"
codesign --force --sign - --timestamp=none "$app_dir/Contents/MacOS/BooksPresence"
codesign --force --sign - --timestamp=none "$app_dir"
python3 "$root_dir/scripts/check-package-sdk.py" "$app_dir" "$(xcrun --sdk macosx --show-sdk-version)" $architectures
python3 "$root_dir/scripts/release/check-info-plist.py" "$info"
python3 "$root_dir/scripts/release/generate-third-party-notices.py" --check

archive_name=$(uname -m); (( ${#architectures} > 1 )) && archive_name=universal
archive_path="$dist_dir/Stillleaf-$archive_name.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive_path"

print "Created $app_dir ($(plutil -extract CFBundleShortVersionString raw "$info") build $(plutil -extract CFBundleVersion raw "$info"), ad-hoc signed"
print "Downloadable archive: $archive_path"
print "Move Stillleaf.app to /Applications or ~/Applications yourself, then open it."
print "The package does not install a global service or enable login startup automatically."
