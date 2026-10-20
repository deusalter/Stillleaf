# Stillleaf for iPhone and iPad

The reading journal and offline EPUB reader for iOS 17 and later. Design, scope,
privacy and App Store notes: [docs/IOS_APP.md](../docs/IOS_APP.md).

## Build

Requires full Xcode 26 and Node.js 22.12+ with npm.

```sh
iOS/scripts/generate-project.sh      # pinned XcodeGen → iOS/Stillleaf.xcodeproj (not committed)
open iOS/Stillleaf.xcodeproj         # scheme “Stillleaf”; set your team under Signing to run on a device
```

The first build runs `scripts/build-reader-assets.sh` into `iOS/build/ReaderAssets`
and copies the renderer into the app as `Reader/`, as the Mac package does. After
changing `Reader/desktop/reader`, delete `iOS/build/ReaderAssets` to rebuild it.

Command-line build and tests (what CI runs):

```sh
iOS/scripts/ci-build-and-test.sh
```

## Layout

| Path | Contents |
| --- | --- |
| `project.yml` | XcodeGen spec: app and test targets, the repository package dependency, the renderer build phase |
| `Stillleaf/Model` | Platform-neutral model: `Journal` (store, tracking, import, edits, data), reader event validation, covers, wording |
| `Stillleaf/Reader` | `WKWebView` host for the shared renderer, and its SwiftUI wrapper |
| `Stillleaf/Views`, `Stillleaf/App` | SwiftUI tabs: Today, Library, History (calendar and timeline), Reviews, Settings |
| `Stillleaf/Resources` | Asset catalog (icon, accent, launch colour) and `PrivacyInfo.xcprivacy` |
| `StillleafTests` | XCTest bundle run on a simulator, with a synthetic EPUB writer |
| `scripts` | Project generation, CI driver, local model check, icon generator |

Shared with the Mac app: `BooksCore` and `BooksPlatform` through `../Package.swift`,
the renderer, and three Mac files compiled directly (`shared-sources.sh` lists them).
Keep those files Foundation + `BooksCore` only.

## Checks without Xcode

On a Mac with Command Line Tools only:

```sh
iOS/scripts/check-model-local.sh
```

This compiles the model with the shared Mac files against the macOS build of
`BooksCore`/`BooksPlatform`. It runs the model smoke with both ZIP readers, then
runs the full EPUB import suite through the iOS (portable) ZIP reader. SwiftUI
and UIKit code is verified only by the CI build.

## Icon

`swift iOS/scripts/generate-app-icon.swift iOS/Stillleaf/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`
re-renders the opaque 1024 px icon from the Pageleaf geometry.
