# Distributing Stillleaf for macOS

Stillleaf ships as a **Developer ID–signed, notarized download from its website**, not through
the Mac App Store. This page records why, how releases are built, and what the website must host.
The step-by-step procedure is [the release checklist](RELEASE_CHECKLIST.md); what the app does
with data is [the privacy statement](PRIVACY.md).

## Why not the Mac App Store

Every Mac App Store app must run in the App Sandbox. Three of Stillleaf's features cannot work
inside it, and the entitlements that would loosen the sandbox enough are ones App Review does not
grant for this kind of use:

1. **Apple Books tracking reads another app's interface.** `BooksCapture` uses the Accessibility
   API on the Books process: its focused window, roles, identifiers and the footer page marker
   (`Sources/BooksPlatform/BooksCapture.swift`, `BooksWindowObserver.swift`). Apple's App Sandbox
   Design Guide says "you cannot sandbox an assistive app such as a screen reader, and you
   cannot sandbox an app that controls another app". No entitlement gives a sandboxed app
   Accessibility access to another process's interface.
2. **Finished-book sync and covers read Apple Books' private library.** `BooksCatalog` opens
   `~/Library/Containers/com.apple.iBooksX/Data/Documents/BKLibrary/*.sqlite` read-only, and
   `CoverCache` reads `com.apple.BKAgentService`'s `Books.plist` and the EPUBs it lists. A
   sandboxed app sees only its own container and files the user picks. Reaching another app's
   container needs `temporary-exception` file entitlements. App Review treats these as
   last-resort exceptions and does not grant them for reading another app's private database.
3. **Discord Rich Presence talks to Discord's local socket.** `DiscordPresence` connects to the
   `discord-ipc-N` Unix domain socket in the user's `$TMPDIR`. Inside the sandbox, `$TMPDIR`
   resolves to Stillleaf's own container, so Discord's socket is not even visible. Connecting to
   it would again need a temporary-exception entitlement for another app's path.

Smaller conflicts: **Uninstall** moves the app bundle to the Trash, and sandboxed apps cannot
modify their own bundle. Apple Books sync and capture would also need redesigning around
security-scoped bookmarks.

A Mac App Store edition is possible later only as a different product: the built-in EPUB reader
and journal, without Apple Books tracking or Discord. That is a product decision, not a
packaging task.

Developer ID keeps every feature and still gives users Apple's protections:

- The hardened runtime blocks code injection and debugging.
- Notarization means Apple scanned the exact binary for malware.
- Gatekeeper verifies the stapled ticket on first launch, even offline.

## Release pipeline

| Step | Script | Notes |
|---|---|---|
| Build | `scripts/package-app.sh` with `STILLLEAF_UNIVERSAL=1` | `build-local.sh` per architecture (arm64, x86_64), joined with `lipo`. Stamps the build number and update-feed URL into Info.plist, then copies `THIRD_PARTY_NOTICES.md`. |
| Info.plist gate | `scripts/release/check-info-plist.py` | Runs on every package, and in stricter `--release` mode for releases. |
| Notices gate | `scripts/release/generate-third-party-notices.py --check` | Fails when reader dependencies change without regenerating the notices. |
| Sign | `scripts/release/sign-app.sh` | Signs inside-out: dylibs, then `books-diagnostic`, then the bundle. Uses `--options runtime --timestamp` and the reviewed entitlements. No `--deep`. |
| Notarize | `scripts/release/notarize.sh` | `notarytool submit --wait`, keeps the notary log, then `stapler staple` and `validate`. Runs once for the app and once for the disk image. |
| Package | `scripts/release/make-dmg.sh` | Compressed HFS+ image with an Applications shortcut, signed with the same identity. A zip of the stapled app is produced too. |
| Verify | `scripts/release/verify-release.py` | Checks strict signature validity, hardened runtime, Developer ID authority, one Team ID, secure timestamps, exact entitlements, stapled tickets and Gatekeeper's verdict on the app and the image. |
| Feed | `scripts/release/make-update-feed.py` | Writes `macos.json` and `release-manifest.json` with the image's SHA-256. |
| Orchestrate | `scripts/release/build-release.sh` | Runs all of the above. Output goes to `.build/release-artifacts/<version>-<build>/`. |
| CI | `.github/workflows/release.yml` | Tags `vX.Y.Z` produce a notarized draft GitHub release. Without secrets, it builds an unsigned preview and says so. |

The pipeline degrades on purpose. Without a signing identity it produces an ad-hoc preview named
`Stillleaf-<version>-adhoc.dmg`. With an identity but no notary credentials it produces
`-signed`. It never produces an unlabeled image that Gatekeeper would reject. Tag builds set
`STILLLEAF_REQUIRE_NOTARIZATION=1` whenever signing secrets exist, so a misconfigured notary key
fails the build instead of being skipped. Credentials come only from environment variables, a
`notarytool` keychain profile, or GitHub secrets ([checklist](RELEASE_CHECKLIST.md#one-time-setup)).

Release builds must use the newest SDK (the workflow uses Xcode 26 on `macos-26`). Liquid Glass
and other macOS 26 behaviour depends on the linked SDK; `check-package-sdk.py` records it. A
Command Line Tools build on an older SDK is a working app but not a release candidate.

## Entitlements

`assets/Stillleaf.entitlements` is deliberately empty, and `verify-release.py` fails if any signed
binary carries something else. Review of each candidate entitlement:

| Entitlement | Needed? | Why |
|---|---|---|
| `com.apple.security.app-sandbox` | No | Incompatible with Apple Books capture and Discord IPC (above). |
| `cs.allow-jit`, `cs.allow-unsigned-executable-memory` | No | WKWebView runs JavaScript in WebKit's own WebContent process, not in Stillleaf. |
| `cs.disable-library-validation` | No | `libBooksCore`/`libBooksPlatform` are signed with the same Team ID. The `libarchive` loaded by `EPUBPublicationImporter` is an Apple platform library. |
| `cs.allow-dyld-environment-variables` | No | Not used. |
| `automation.apple-events` | No | Stillleaf sends no Apple Events, so there is no `NSAppleEventsUsageDescription` either. |
| `get-task-allow` | Never | Makes a build debuggable; notarization rejects it. |

Accessibility, other apps' data and login items are user consents (TCC and Service Management),
not entitlements. Spawning `/usr/bin/unzip` (cover extraction) is allowed under the hardened
runtime.

## Version and build numbers

- **Marketing version**: `CFBundleShortVersionString` in `assets/Info.plist`, `MAJOR.MINOR.PATCH`.
  It changes only in a reviewed pull request. The release tag must be `v` plus that version;
  `build-release.sh` refuses a mismatch.
- **Build number**: `CFBundleVersion` is stamped at package time as `git rev-list --count HEAD`.
  The same commit always gets the same number, and each later commit on `main` gets a larger one.
  This depends on `main` never being rewritten, which the repository rules already require. The
  committed value (17) is only a placeholder for `git archive` exports. Release checks reject
  values under 100.
- The update check compares **build numbers only**. Marketing versions are for people.

## Bundle identity

Releases keep `com.bookspresence.app`, the `BooksPresence` executable and the
`~/Library/Application Support/BooksPresence/` folder. Existing users keep their history,
settings and login item.

macOS ties Accessibility grants to the code signature. Moving from today's ad-hoc builds to
Developer ID therefore changes the designated requirement once. Existing users must re-enable
Stillleaf under Privacy & Security → Accessibility after their first Developer ID update. Later
Developer ID updates keep the grant, because the requirement then depends on the Team ID and
bundle identifier, not on each build's hash.

## Updates

**Decision: a lightweight "Check for Updates" against a JSON feed hosted with the website. No
Sparkle for now.**

Sparkle 2 is the standard for apps distributed outside the App Store, with EdDSA-signed appcasts,
in-app installation and delta updates. It was weighed against the project's
no-external-dependency rule (README: "The Swift package has no external package dependencies"):

- It would be the first third-party binary framework in the bundle, with its own XPC helpers to
  sign, notarize and keep patched.
- It adds an EdDSA private key to protect alongside the Developer ID certificate.
- Its installer replaces the running app, so a bug or compromise there is high-impact.
- For one maintainer and a modest release cadence, an in-app prompt plus a browser download
  covers the need. The download path also gets Gatekeeper's full first-launch check of a fresh,
  quarantined, notarized image.

Revisit Sparkle when release frequency or user count makes manual replacement a real burden. It
is the one dependency worth an exception then, since it is well maintained and MIT licensed. The
feed and build-number scheme here would carry over to an appcast.

What is implemented (`BooksCore/UpdateFeed.swift`, `BooksPlatform/UpdateChecker.swift`,
`BooksPresence/UpdateController.swift`):

- **Stillleaf → Check for Updates…** in the menu bar. Settings → Data & privacy → Updates shows the
  version and status, and has a **Check automatically** switch: once a day, **off by default**
  like every other networked feature.
- The request is one HTTPS GET with an ephemeral session: no cookies, no cache, redirects
  refused. Its User-Agent is `Stillleaf/<version>` and nothing else.
- The feed is validated:
  - it is size-limited and has a schema version;
  - its bundle identifier matches the app;
  - its links are credential-free HTTPS;
  - it carries a 64-hex SHA-256;
  - a release whose minimum macOS is newer than the user's is reported, never offered.
- Stillleaf never downloads or installs anything. **Open Download Page** opens the release page
  in the browser. An automatic check that finds an update waits until the user next brings
  Stillleaf forward, so it never steals focus, and it announces each build once.
- Builds without `StillleafUpdateFeedURL` in Info.plist (all development builds) cannot contact
  the network for updates. Packaging inserts the key only when `STILLLEAF_UPDATE_FEED_URL` is
  set.

### Update feed

`macos.json`, written by `make-update-feed.py`:

```json
{
  "schemaVersion": 1,
  "bundleIdentifier": "com.bookspresence.app",
  "latest": {
    "version": "1.6.0",
    "build": 612,
    "minimumSystemVersion": "13.0",
    "publishedAt": "2026-11-01T18:00:00Z",
    "url": "https://HOST/download/Stillleaf-1.6.0.dmg",
    "sha256": "64 lowercase hex digits",
    "size": 31457280,
    "releaseNotesURL": "https://HOST/releases/1.6.0"
  }
}
```

`url`, `version` and `sha256` are the same fields as the website's `ReleaseArtifact`
(`website/src/releases.js`). One `release-manifest.json` can fill both; set `verified: true` only
after the checklist is complete.

### URL shapes the website should host

| Purpose | Shape | Requirements |
|---|---|---|
| Update feed | `https://HOST/updates/macos.json` | Must not redirect; the app refuses redirects, so use the final host (apex vs `www`). `Content-Type: application/json`. Short cache (`max-age=300`). |
| Disk image | `https://HOST/download/Stillleaf-<version>.dmg` | Immutable per version. Never overwrite a published file; ship a new version instead. |
| Zip (optional) | `https://HOST/download/Stillleaf-<version>.zip` | Same rule. |
| Checksums | `https://HOST/download/Stillleaf-<version>.SHA256SUMS` | From the release artifacts. |
| Release notes | `https://HOST/releases/<version>` | Opened by **Open Download Page**. It should link the image, checksum and system requirements. |
| Privacy | `https://HOST/privacy` | Publish [PRIVACY.md](PRIVACY.md) unchanged in substance. |

The release workflow reads these as repository **variables** (not secrets):
`STILLLEAF_UPDATE_FEED_URL`, `STILLLEAF_DOWNLOAD_BASE_URL` (`https://HOST/download`) and
`STILLLEAF_RELEASE_NOTES_URL` (`https://HOST/releases/{version}`). GitHub Releases can host the
image instead (`https://github.com/deusalter/Stillleaf/releases/download/v<version>/…`). The
feed must still live at a stable URL.

## First launch from a download

A quarantined app opened where it was downloaded runs from Gatekeeper's randomized read-only
"App Translocation" path. Opened from the mounted image, it runs from a read-only volume. In both
cases Stillleaf now:

- does **not** register itself as a login item. Previously that registration pointed at a path
  that disappears, and the one-time flag stopped a later retry;
- explains how to move the app to Applications (**Quit and Move** / **Continue Anyway**).

Once installed, the first launch behaves as before.

## Known limitations

- **macOS 26 icon style.** `BooksPresence.icns` is a classic full-size icon. macOS 26 may show
  non-conforming legacy icons inside its rounded-square treatment. A layered Icon Composer
  `.icon` compiled into `Assets.car` needs `actool` from full Xcode. It can be added to the CI
  release build later; the current icon is complete at every required size.
- **"Access data from other apps".** On macOS 14 and later, reading Apple Books' library (Sync
  finished books, on by default) may make macOS ask whether Stillleaf may access data from other
  apps. Apple documents no Info.plist purpose string for that prompt. The checklist requires
  recording which prompts actually appear on a clean account.
