# Mac update feed

This is the contract between the website and the Mac release process. The website publishes the feed; the app (or its updater) reads it.

## Where it lives

| File | Path | Format |
| --- | --- | --- |
| Appcast | `/updates/appcast.xml` | [Sparkle 2](https://sparkle-project.org/documentation/publishing/) RSS, one `<item>` for the current release |
| JSON | `/updates/latest.json` | Same facts for a custom updater (schema below) |

With the site on its own domain, the full URL is `https://<domain>/updates/appcast.xml`. For Sparkle, that is the app's `SUFeedURL`. The domain isn't chosen yet (see `DEPLOY.md`), so the release build should take the URL from configuration rather than hard-coding a guess. The paths are set in `src/site-config.js` (`site.updates`); change them only together with the app.

## When it exists

The feed is generated at build time by `src/update-feed.js` and written only when **all** of these hold:

1. `publication.approved` is `true` in `src/releases.js`.
2. The `macos` release is `state: "available"` with a complete, `verified: true` artifact (`getDownload()` returns a link).
3. `site.origin` is set in `src/site-config.js`.

Otherwise neither file is built. A missing feed (HTTP 404) must mean "no update" to the app, never an error dialog.

## What release engineering supplies

Fill the `macos` entry's `artifact` in `src/releases.js` from the exact notarized DMG:

| Field | Example | Source |
| --- | --- | --- |
| `url` | `https://…/Stillleaf-1.6.0.dmg` | Permanent public HTTPS URL of the stapled DMG |
| `version` | `1.6.0` | `CFBundleShortVersionString` |
| `build` | `18` | `CFBundleVersion`; must increase every release, since Sparkle compares it |
| `minimumSystemVersion` | `13.0` | `LSMinimumSystemVersion` |
| `length` | `18204331` | DMG size in bytes |
| `publishedAt` | `2026-11-02T17:00:00Z` | Release time, ISO 8601 with timezone |
| `sha256` | 64 hex digits | `shasum -a 256 Stillleaf-1.6.0.dmg` |
| `edSignature` | 88-char base64 (optional) | Sparkle `sign_update` output; required if the app sets `SUPublicEDKey` |
| `verified` | `true` | Only after the human release check (README, “Publication gates”) |

`npm run check:release` validates the shape offline. It cannot prove the URL works, the checksum matches, or the build is notarized; the release checklist does that.

## JSON schema (`latest.json`)

```json
{
  "schemaVersion": 1,
  "platform": "macos",
  "version": "1.6.0",
  "build": "18",
  "minimumSystemVersion": "13.0",
  "publishedAt": "2026-11-02T17:00:00Z",
  "url": "https://…/Stillleaf-1.6.0.dmg",
  "length": 18204331,
  "sha256": "…64 lowercase hex…",
  "edSignature": "…optional…",
  "downloadPage": "https://<domain>/#downloads"
}
```

A custom updater should compare `build` numerically, ignore releases whose `minimumSystemVersion` is newer than the running macOS, verify `sha256` (and the code signature) before installing, and treat any parse error as "no update".

## Privacy

The privacy policy already discloses update checks as a request to this website containing no reading data. If the updater sends anything else (for example Sparkle's optional system profile), update `privacy/index.html` first.
