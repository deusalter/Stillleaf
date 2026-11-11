# App Store listing for Stillleaf on iPhone and iPad (draft)

A starting draft for App Store Connect. Every claim below is something the iOS app
does today; nothing mentions Apple Books, Discord or the Mac-only features. The
wording is yours to change. Character limits are App Store Connect's.

## Name and subtitle

| Field | Text | Limit |
| --- | --- | --- |
| Name | Stillleaf | 30 |
| Subtitle | EPUB reader & reading journal | 30 |

## Promotional text (170)

Read your EPUBs on a clean page and let the reading count itself: time, pages, a
daily goal and a streak, all kept on your device.

## Description

Stillleaf is a quiet place to read your own EPUBs, and a journal that fills itself
in while you do.

READ
• Open DRM-free EPUBs from Files, or share them to Stillleaf from Mail, Safari or AirDrop.
• One clean page. Tap the middle for contents, search, bookmarks and themes; tap again and they are gone.
• More than a dozen page themes, including a pure black one for OLED screens, with your choice of typeface, size, spacing and margins.
• Turn pages or scroll continuously. On an iPad in landscape, read two pages side by side.
• Highlight in five colours and write notes in the margin.
• Search the whole book on your device.

TRACK
• Reading time counts only while a book is open in front of you. Nothing runs in the background.
• Pages count as you move forward through the book.
• A daily goal in pages or minutes, a streak, and a yearly books goal.
• A calendar of every day you read, and each session inside it.
• Mark books finished, rate them in quarter stars and write a review.
• Log paper books by hand.
• An optional daily reminder, on days when your goal is still open.

YOURS
• No account. No network requests. No analytics.
• Export your journal as JSON or CSV, or back it up whole, whenever you like.
• The same journal format as Stillleaf for Mac.

Stillleaf opens DRM-free EPUB 2 and EPUB 3 books. It cannot open books protected
with DRM.

## Keywords (100, comma separated, no spaces)

epub,ebook,reader,reading,tracker,streak,journal,books,goal,log,library,highlight,notes,habit

## Categories and rating

- Primary category: Books. Secondary: Productivity.
- Age rating: 4+ (no objectionable content, no web access, no user-generated content shared with others).

## App Privacy answers

- Data collection: **Data Not Collected**.
- Tracking: none. The privacy manifest declares no tracking and no collected data types.
- Privacy policy URL and support URL: needed before submission (see `docs/IOS_APP.md`).

## Notes for App Review

Stillleaf reads DRM-free EPUB files the user already has. To try it: open the
Files app, pick any EPUB and share it to Stillleaf, or use the + button in the app
and choose Import EPUBs. The app makes no network requests and has no account.
Notifications are used only for the optional daily reminder in Settings, which is
off by default.

## Screenshots

CI uploads every screen at the sizes App Store Connect asks for in the
`Stillleaf-iOS-screenshots` artifact: the largest iPhone (6.9″) with no prefix and
the 13″ iPad as `ipad-…`. A suggested set, in order:

1. `01-reading-now` — Pick up where you left off
2. `12-reader-page` — One clean page
3. `15-reader-themes` — Your theme, your typeface
4. `25-reader-highlighted` — Highlights and notes
5. `03-journal-calendar` — Every day you read
6. `30-finish-rate` — Finish, rate, remember
7. `02-library` — Your library

The pictures use generated sample books, so there is no third-party cover art or
text in them.

## What's New (first version)

The first version of Stillleaf for iPhone and iPad.
