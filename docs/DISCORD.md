# Discord Rich Presence

BooksPresence uses Discord's native, local IPC socket. It does not contact Discord's HTTP API, authenticate a Discord account, request OAuth permission, or store a user token. Tracking remains local if Discord is not running.

Sharing is off by default. To enable it, create a Discord application in the [Discord Developer Portal](https://discord.com/developers/applications), copy its **Application ID** into BooksPresence settings, and enable sharing. Leave the optional asset key empty unless you have uploaded artwork to that application. If you upload an asset with a key such as `books`, enter that exact key when you want an image. Asset keys are names registered with the Discord application; BooksPresence never sends a local cover path, uploads artwork, or accepts a remote artwork URL.

When sharing is enabled during eligible reading, the activity uses Discord's supported `Playing` type (`0`). It contains `Reading <title>`, the author when available, reliable page/progress text when available, and a start time calculated from credited reading time only. For automatic Books tracking, switching apps stops credited time but retains a card marked “Paused,” without a running timestamp. It expires 20 minutes after the last observed page turn (or foreground reading interaction where page metadata is unavailable). Repeated polling and activity in other apps do not extend that deadline. Returning to a fresh reading session resumes the credited-time display. Explicit tracking/sharing disable, per-book exclusion, lock/sleep, lost permission, capture failure and app exit clear the activity immediately.

The implementation follows Discord's [RPC IPC transport](https://github.com/discord/discord-api-docs/blob/main/developers/topics/rpc.mdx): it searches the documented local `discord-ipc-0` through `discord-ipc-9` paths, sends the version-1 handshake, handles framed partial reads and writes plus ping/pong, backs off reconnections, and limits activity updates. Discord documents `SET_ACTIVITY` types 0, 2, 3, and 5; BooksPresence uses 0 and does not invent a `Reading` type.

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

Run `./scripts/package-app.sh` from the repository root. It builds a local `dist/BooksPresence.app`, sets `LSUIElement` so the app starts without a Dock icon or initial window, bundles `books-diagnostic` alongside the app executable, and applies an ad-hoc signature. Move the resulting app to `/Applications` or `~/Applications` yourself. Packaging does not automatically install it globally or register it at login.

## Setup and connection state

1. Open Discord desktop and sign in to the account whose activity should appear.
2. Create an application named BooksPresence in the Developer Portal, then copy Application ID from General Information. No bot, token or OAuth redirect is needed for this Rich Presence flow.
3. Paste the ID in Settings → Discord and apply the details. Leave the artwork key empty unless that exact asset exists.
4. Enable sharing and read in a supported foreground Books window. BooksPresence needs its own Accessibility permission.

A missing Application ID is shown even while tracking is paused. Activity is “sent; waiting for confirmation” until a matching SET_ACTIVITY response arrives; only then does the app report “shared.” Rejections and disconnects keep a useful status, and Settings retains the last connection result when opening the dashboard pauses reading. Account activity-privacy settings can still affect visible rendering.

The menu uses a nonactivating native panel so checking it does not intentionally switch away from Books. Opening the full dashboard pauses automatic reading time while retaining the paused Discord card until its inactivity deadline. Synthetic socket tests check acknowledgement ordering, stale-error handling and immediate paused/resumed payloads without contacting Discord.
