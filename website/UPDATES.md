# Mac update feed

This is the contract between the website, the Mac app and the release scripts. There is one feed, in one format:

| Who | Role |
| --- | --- |
| Website (`src/update-feed.js`) | Publishes `/updates/macos.json` from the verified `macos` entry in `src/releases.js`. |
| Mac app (`Sources/BooksCore/UpdateFeed.swift`, `UpdateChecker.swift`) | Reads it from `StillleafUpdateFeedURL` in Info.plist. Only release builds set that key. |
| Release scripts (`scripts/release/make-update-feed.py`) | Write the same `macos.json` beside each release, plus `release-manifest.json` with the artifact fields for `releases.js`. |

The shared example is [`Tests/Fixtures/update-feed/macos.json`](../Tests/Fixtures/update-feed/macos.json). `tests/site.test.mjs` and `scripts/release/test-update-feed-contract.py` check the website's and the release script's output against it byte for byte. The app's `UpdateCheckerTests` and `scripts/update-feed-smoke.swift` parse the same file. Change it only together with all of them.

## Where it lives

`https://<domain>/updates/macos.json`. The app sets `StillleafUpdateFeedURL` to this exact URL at packaging time (`STILLLEAF_UPDATE_FEED_URL`). The path is `site.updates.feedPath` in `src/site-config.js`.

The app refuses redirects, so the URL must be final. Use the canonical host (apex or `www`), not a forwarding one. Serve it as `Content-Type: application/json` with a short cache (`max-age=300`). See [DEPLOY.md](DEPLOY.md).

## When it exists

The feed is generated at build time and written only when **all** of these hold:

1. `publication.approved` is `true` in `src/releases.js`.
2. The `macos` release is `state: "available"` with a complete, `verified: true` artifact (`getDownload()` returns a link).
3. `site.origin` is set in `src/site-config.js`.

Otherwise no file is built. The app treats a missing feed (HTTP 404) as a failed check, never as an update: Settings shows the status line, and an alert appears only when you check by hand.

## What release engineering supplies

Copy the `macos` entry's `artifact` in `src/releases.js` from `release-manifest.json` (written by `scripts/release/build-release.sh`) for the exact notarized DMG:

| Field | Example | Source |
| --- | --- | --- |
| `url` | `https://…/Stillleaf-1.6.0.dmg` | Permanent public HTTPS URL of the stapled DMG |
| `version` | `1.6.0` | `CFBundleShortVersionString`. Plain `MAJOR.MINOR.PATCH`: the app rejects prerelease suffixes. |
| `build` | `612` | `CFBundleVersion` as a number. It must increase every release, because the app compares builds, not versions. |
| `minimumSystemVersion` | `13.0` | `LSMinimumSystemVersion` |
| `size` | `18204331` | DMG size in bytes |
| `publishedAt` | `2026-11-02T17:00:00Z` | Release time, ISO 8601 with timezone |
| `sha256` | 64 hex digits | `shasum -a 256 Stillleaf-1.6.0.dmg` |
| `verified` | `true` | Only after the human release check (README, “Publication gates”). The manifest starts with `false`. |

The manifest's extra `artifact` and `commit` fields are for the record and are ignored here. `npm run check:release` validates the shape offline. It cannot prove that the URL works, that the checksum matches, or that the build is notarized; the release checklist does that.

## Format (`macos.json`)

```json
{
  "schemaVersion": 1,
  "bundleIdentifier": "com.bookspresence.app",
  "latest": {
    "version": "1.6.0",
    "build": 612,
    "minimumSystemVersion": "13.0",
    "publishedAt": "2026-11-02T17:00:00Z",
    "url": "https://…/Stillleaf-1.6.0.dmg",
    "sha256": "…64 lowercase hex…",
    "size": 18204331,
    "releaseNotesURL": "https://<domain>/#downloads"
  }
}
```

The app:

- rejects a feed whose `bundleIdentifier` is not its own (`site.updates.bundleIdentifier`, tested against `assets/Info.plist`), or whose `schemaVersion` is not 1;
- offers only a larger `build`, and reports, but does not offer, a release whose `minimumSystemVersion` is newer than the running macOS;
- opens `releaseNotesURL` (the site's downloads section) from **Open Download Page**, or `url` when there are no notes;
- never downloads or installs anything itself. The browser downloads the DMG, and Gatekeeper checks the notarized image as usual.

There is no Sparkle appcast. The app has no updater framework (no third-party Swift dependencies), so it does not need one.

## Privacy

An update check is one GET of this file, with `User-Agent: Stillleaf/<version>`, no cookies and no cache. Release builds check once a day only if **Settings → Data & privacy → Updates → Check automatically** is on (off by default), and otherwise only when you choose **Check now** or **Check for Updates…**. The privacy page and `docs/PRIVACY.md` describe exactly this. If the request ever changes, update both first.
