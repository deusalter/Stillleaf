# Discord Rich Presence

Stillleaf uses Discord's native, local IPC socket. It does not contact Discord's HTTP API, authenticate a Discord account, request OAuth permission, or store a user token. Tracking remains local if Discord is not running.

Sharing is off by default. To enable it, create a Discord application in the [Discord Developer Portal](https://discord.com/developers/applications), set the application's display name there (for example, “Reading”), copy its **Application ID** into Stillleaf settings, and enable sharing. The application name shown by Discord belongs to that Developer Portal application; native RPC cannot override it per activity. Leave the optional asset key empty unless you have uploaded a stable generic asset to that application. Asset keys are names registered with the Discord application.

Stillleaf never sends a local cover path or uploads artwork. With explicit reader opt-in, it can query Apple's public iTunes Search metadata with the book title and author. It asks for at most ten e-book results and accepts an image only for one unique exact normalized title-and-author match. The selected URL must be a validated public HTTPS image URL with a normal public DNS host; file, data, HTTP, local/private, credential-bearing, query-bearing and malformed references are rejected. Discord retrieves a valid public image itself. A missing, ambiguous or rejected result uses the configured generic asset when present.

When sharing is enabled during eligible reading, the activity uses Discord's supported client-controlled `Playing` type (`0`). Page mode shows the book title, author, the current layout-specific page and total when available (for example, “Page 100 of 1000”), and pages for the current session; it omits timestamps so Discord does not advance a reading duration. Without page evidence, the activity retains the credited-time display. Presence requires the previously verified Apple Books reading window to remain open. Closing that reader, returning its window to the library, or quitting Apple Books clears the activity instead of using the inactivity grace period. Reopening Books alone does not restore an old card; a fresh verified reader observation is required. Switching apps while the reader stays open stops credited time but retains a card marked “Paused,” without a running timestamp. It expires 20 minutes after the last supported page observation (or foreground reading interaction where page metadata is unavailable). Repeated polling and activity in other apps do not extend that deadline. Returning to a fresh reading session resumes the appropriate display. Explicit tracking/sharing disable, per-book exclusion, lock/sleep, lost permission, capture failure and app exit clear the activity immediately.

The implementation follows Discord's [RPC IPC transport](https://github.com/discord/discord-api-docs/blob/main/developers/topics/rpc.mdx): it searches the documented local `discord-ipc-0` through `discord-ipc-9` paths, sends the version-1 handshake, handles framed partial reads and writes plus ping/pong, backs off reconnections, and limits activity updates. Discord documents `SET_ACTIVITY` types 0, 2, 3, and 5; Stillleaf uses 0 and does not invent a `Reading` type.

Explicit manual sessions remain independent of Books foreground status, for paper books and deliberate side-by-side reading; they use the manual session’s existing interaction/uncertainty rules.

An application ID is required before a real publish can be attempted. It identifies the developer application; it is not a bot/account token, and the owner can differ from the person signed into Discord desktop. This repository does not include the user’s local configuration. A local handshake has returned READY with a user-supplied ID; rendering is a separate end-to-end check. Discord may also reject an unapproved application or a client configuration; the app surfaces a status message and continues local tracking.

On a Command Line Tools-only Mac where XCTest is unavailable, run the framing and payload harness after the local build:

```zsh
./scripts/build-local.sh --diagnostic-only
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
swiftc -sdk "$sdk_path" -target "$(uname -m)-apple-macosx13.0" -enable-testing -I Sources/CSQLite -I .build/local -L .build/local -lBooksCore -lBooksPlatform scripts/discord-smoke.swift -o .build/local/discord-smoke -Xlinker -rpath -Xlinker @executable_path
.build/local/discord-smoke
```

## Packaging

Run `./scripts/package-app.sh` from the repository root. It builds a local `dist/Stillleaf.app`, sets `LSUIElement` so the app starts without a Dock icon or initial window, bundles `books-diagnostic` alongside the app executable, and applies an ad-hoc signature. Move the resulting app to `/Applications` or `~/Applications` yourself. Packaging does not automatically install it globally or register it at login.

## Setup and connection state

1. Open Discord desktop and sign in to the account whose activity should appear.
2. Create an application named Reading in the Developer Portal, then copy Application ID from General Information. No bot, token or OAuth redirect is needed for this Rich Presence flow.
3. Paste the ID in Settings → Discord and apply the details. Leave the artwork key empty unless that exact stable generic asset exists. Automatic public-cover lookup remains off until the reader enables it.
4. Enable sharing and read in a supported foreground Books window. Stillleaf needs its own Accessibility permission.

A missing Application ID is shown even while tracking is paused. Activity is “sent; waiting for confirmation” until a matching SET_ACTIVITY response arrives; only then does the app report “shared.” Rejections and disconnects keep a useful status, and Settings retains the last connection result when opening the dashboard pauses reading. Account activity-privacy settings can still affect visible rendering.

The menu uses a nonactivating native panel so checking it does not intentionally switch away from Books. Opening the full dashboard pauses automatic reading time while retaining the paused Discord card until its inactivity deadline, provided the Books reader remains open. Synthetic socket tests check acknowledgement ordering, stale-error handling and immediate paused/resumed payloads without contacting Discord. Resolver fixtures cover exact, mismatched and ambiguous Apple metadata without downloading an image; live Discord rendering remains a separate check.

The current position and total come from the verified reader footer, not saved catalog progress. A resize or changed pagination starts a new page-counting baseline and replaces the displayed pair; it does not credit the numeric jump as reading. If Books briefly hides the total, the last observed total is retained only within the same active book, session and layout. Unknown totals remain omitted.
