#!/bin/zsh
set -euo pipefail

root_dir=${0:A:h:h}
dist_dir="$root_dir/dist"
app_dir="$dist_dir/Stillleaf.app"
binary_dir="$root_dir/.build/local"

if [[ ! -x "$root_dir/scripts/build-local.sh" ]]; then
  print -u2 "Missing scripts/build-local.sh. Build with a full Xcode toolchain using: swift build -c release"
  exit 1
fi

"$root_dir/scripts/generate-pageleaf.sh"
"$root_dir/scripts/build-local.sh"

if [[ ! -x "$binary_dir/BooksPresence" || ! -x "$binary_dir/books-diagnostic" ]]; then
  print -u2 "Local build did not produce BooksPresence and books-diagnostic in $binary_dir"
  exit 1
fi

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Frameworks"
cp "$root_dir/assets/Info.plist" "$app_dir/Contents/Info.plist"
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
python3 "$root_dir/scripts/check-package-sdk.py" "$app_dir" "$(xcrun --sdk macosx --show-sdk-version)"

archive_path="$dist_dir/Stillleaf-$(uname -m).zip"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive_path"

print "Created $app_dir"
print "Downloadable archive: $archive_path"
print "Move Stillleaf.app to /Applications or ~/Applications yourself, then open it."
print "The package does not install a global service or enable login startup automatically."
