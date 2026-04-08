# Discord Rich Presence

BooksPresence uses Discord's native, local IPC socket. It does not contact Discord's HTTP API, authenticate a Discord account, request OAuth permission, or store a user token. Tracking remains local if Discord is not running.

Sharing is off by default. To enable it, create a Discord application in the [Discord Developer Portal](https://discord.com/developers/applications), copy its **Application ID** into BooksPresence settings, and enable sharing. Create an application asset with a generic key such as `books`, then enter that key in settings if you want an image. Asset keys are names registered with the Discord application; BooksPresence never sends a local cover path, uploads artwork, or accepts a remote artwork URL.

When sharing is enabled during eligible reading, the activity uses Discord's supported `Playing` type (`0`). It contains `Reading <title>`, the author when available, reliable page/progress text when available, and a start time calculated from credited reading time only. Pauses are excluded. The activity clears immediately when sharing is disabled, tracking pauses, the current book is excluded from sharing, or the app exits.

The implementation follows Discord's [RPC IPC transport](https://github.com/discord/discord-api-docs/blob/main/developers/topics/rpc.mdx): it searches the documented local `discord-ipc-0` through `discord-ipc-9` paths, sends the version-1 handshake, handles framed partial reads and writes plus ping/pong, backs off reconnections, and limits activity updates. Discord documents `SET_ACTIVITY` types 0, 2, 3, and 5; BooksPresence uses 0 and does not invent a `Reading` type.

An application ID is required before a real publish can be attempted. This repository does not include one, so live Discord publication has not been validated here. Discord may also reject an unapproved application or a client configuration; the app surfaces a status message and continues local tracking.

On a Command Line Tools-only Mac where XCTest is unavailable, run the framing and payload harness after the local build:

```zsh
./scripts/build-local.sh --diagnostic-only
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
swiftc -sdk "$sdk_path" -target "$(uname -m)-apple-macosx13.0" -enable-testing -I Sources/CSQLite -I .build/local -L .build/local -lBooksCore -lBooksPlatform scripts/discord-smoke.swift -o .build/local/discord-smoke -Xlinker -rpath -Xlinker @executable_path
.build/local/discord-smoke
```

## Packaging

Run `./scripts/package-app.sh` from the repository root. It builds a local `dist/BooksPresence.app`, sets `LSUIElement` so the app starts without a Dock icon or initial window, bundles `books-diagnostic` alongside the app executable, and applies an ad-hoc signature. Move the resulting app to `/Applications` or `~/Applications` yourself. Packaging does not automatically install it globally or register it at login.
