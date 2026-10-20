# macOS release checklist

The procedure for publishing a Stillleaf release. Background and design decisions are in
[DISTRIBUTION.md](DISTRIBUTION.md). Never store certificates, passwords or API keys in the
repository; they belong in the login keychain, a `notarytool` profile or GitHub secrets.

## One-time setup

### Apple Developer account

1. Enrol in the Apple Developer Program as an individual or an organization. The **Account
   Holder** role is needed to create Developer ID certificates.
2. Create a **Developer ID Application** certificate (developer.apple.com → Certificates, or
   Xcode → Settings → Accounts → Manage Certificates). Use a CSR generated on this Mac so the
   private key stays in your login keychain. Check it:

   ```sh
   security find-identity -v -p codesigning   # "Developer ID Application: NAME (TEAMID)"
   ```

3. Back up the certificate and private key as a password-protected `.p12`
   (Keychain Access → My Certificates → Export). Keep the file and password in a password
   manager, never in the repository.
4. Create an **App Store Connect API key** for notarization: App Store Connect → Users and
   Access → Integrations → Team Keys, role **Developer**. Download `AuthKey_<KEYID>.p8` (it can
   be downloaded only once) and note the Key ID and Issuer ID.
5. Store a local notary profile, then remove the downloaded key file:

   ```sh
   xcrun notarytool store-credentials stillleaf-notary \
     --key ~/Downloads/AuthKey_KEYID.p8 --key-id KEYID --issuer ISSUER-UUID
   ```

### GitHub

Repository → Settings → Secrets and variables → Actions:

| Kind | Name | Value |
|---|---|---|
| Secret | `MACOS_SIGNING_CERTIFICATE_P12` | `base64 -i DeveloperID.p12 \| pbcopy` |
| Secret | `MACOS_SIGNING_CERTIFICATE_PASSWORD` | The `.p12` password |
| Secret | `MACOS_SIGNING_IDENTITY` | `Developer ID Application: NAME (TEAMID)` |
| Secret | `NOTARY_API_KEY_P8` | Contents of `AuthKey_KEYID.p8` (raw or base64) |
| Secret | `NOTARY_API_KEY_ID` | Key ID |
| Secret | `NOTARY_API_ISSUER_ID` | Issuer ID |
| Variable | `STILLLEAF_UPDATE_FEED_URL` | `https://HOST/updates/macos.json` |
| Variable | `STILLLEAF_DOWNLOAD_BASE_URL` | `https://HOST/download` |
| Variable | `STILLLEAF_RELEASE_NOTES_URL` | `https://HOST/releases/{version}` |

Consider a protected `release` environment with required reviewers, and restrict `v*` tag
creation to maintainers.

## Every release

### 1. Prepare

- [ ] `main` is green: macOS checks, Project checks and Native chrome.
- [ ] Bump `CFBundleShortVersionString` in `assets/Info.plist` in a pull request (`MAJOR.MINOR.PATCH`). Merge it.
- [ ] If reader dependencies changed, the notices are regenerated:
      `scripts/build-reader-assets.sh && scripts/release/generate-third-party-notices.py`.
      Packaging fails when they are stale.
- [ ] [PRIVACY.md](PRIVACY.md) still matches behaviour. Recheck it if networking, storage,
      Apple Books access or permissions changed.
- [ ] Release notes are drafted: user-visible changes, then known issues.

### 2. Build

Preferred: tag `main` and let CI build.

```sh
git switch main && git pull --ff-only
git tag -s v1.6.0 -m "Stillleaf 1.6.0"   # or -a if you do not sign tags
git push origin v1.6.0
```

The `macOS release` workflow builds on `macos-26` with Xcode 26, signs, notarizes and staples
the app and the disk image, verifies them, and opens a **draft** GitHub release. If secrets are
missing it builds an unsigned preview and reports that. A tag build with signing secrets but no
working notarization fails.

Local alternative, on a Mac with full Xcode selected:

```sh
STILLLEAF_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" \
STILLLEAF_NOTARY_PROFILE=stillleaf-notary STILLLEAF_REQUIRE_NOTARIZATION=1 \
STILLLEAF_UPDATE_FEED_URL=https://HOST/updates/macos.json \
STILLLEAF_DOWNLOAD_BASE_URL=https://HOST/download \
STILLLEAF_RELEASE_NOTES_URL='https://HOST/releases/{version}' \
scripts/release/build-release.sh
```

Output goes to `.build/release-artifacts/<version>-<build>/`: `Stillleaf-<version>.dmg` and
`.zip`, `SHA256SUMS`, `macos.json`, `release-manifest.json`, and `logs/` with notary logs and
verification output.

### 3. Verify the exact artifact

Use the files from the draft release or CI artifact, not a local rebuild.

- [ ] `shasum -a 256 -c SHA256SUMS` passes.
- [ ] `scripts/release/verify-release.py <mounted>/Stillleaf.app Stillleaf-<version>.dmg --level notarized` passes.
- [ ] Notary logs (`logs/notary-*-log.json`) list no issues.
- [ ] `lipo -archs Stillleaf.app/Contents/MacOS/BooksPresence` prints `x86_64 arm64`.
- [ ] Download through a browser so the file is quarantined, on a clean macOS user account
      (ideally also on macOS 13 and on an Intel Mac):
  - [ ] Opening the disk image and the app shows the standard "downloaded from the internet"
        prompt only, with no "cannot be opened" or malware warning.
  - [ ] Opening the app straight from the image shows **Move Stillleaf to your Applications
        folder**, and does not add a login item.
  - [ ] Drag to Applications and open: the welcome tour appears, Open at login is enabled once,
        and nothing crashes with no history, no Books library and no permissions.
  - [ ] Record every permission prompt that appears and when, especially "access data from
        other apps". Update PRIVACY.md if it differs.
  - [ ] Import a synthetic EPUB and read a few pages: progress and time are recorded.
  - [ ] Optional Apple Books: grant Accessibility, open a book, confirm tracking.
  - [ ] Stillleaf → About shows the right version, build and copyright.
        Stillleaf → Check for Updates… works against the published feed.
  - [ ] Delete reading data, then Uninstall, behave as PRIVACY.md describes.
- [ ] **Upgrade test.** Install the previous release, add synthetic history, then replace the
      app with the new one. History and settings remain. The first Developer ID release asks
      existing users to re-enable Accessibility once; later releases must not.

### 4. Publish

- [ ] Upload `Stillleaf-<version>.dmg` (and optionally the `.zip`) to
      `https://HOST/download/` under its versioned name. Never overwrite an existing version.
- [ ] Publish the release notes page `https://HOST/releases/<version>`.
- [ ] Update the website's macOS `ReleaseArtifact` (`url`, `version`, `sha256`, then `verified: true`).
- [ ] Publish `macos.json` at the feed URL **last**, so the app announces only downloadable
      releases. Check that it serves directly without a redirect:
      `curl -sI https://HOST/updates/macos.json`.
- [ ] Publish the draft GitHub release.

### 5. If something is wrong after publishing

- Restore the previous `macos.json` straight away; users who have not updated will not be
  offered the bad build.
- Fix forward with a new version. Build numbers only increase, so a rollback is a new, higher
  build of the old code, never a re-published older file.
- If a signing key is compromised, revoke the certificate in the developer portal and contact
  Apple Developer Support. Revocation can also block existing builds signed with that
  certificate, so agree on its timing with Apple, then ship a build signed with a new
  certificate.
