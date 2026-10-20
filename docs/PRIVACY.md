# Stillleaf privacy statement (macOS)

Stillleaf is a reading journal that runs on your Mac. It has no accounts, no analytics, no
telemetry, no advertising and no crash reporting of its own. Your reading history, books, notes
and settings stay on your Mac. The few network connections it can make are listed below,
together with what triggers each one.

This statement describes Stillleaf for macOS. Keep it in step with the code: any change to what
the app reads, stores or sends must update this page in the same pull request.

## What stays on your Mac

All data lives in your user account. Nothing is uploaded or synced by Stillleaf.

| Data | Location |
|---|---|
| Reading history: sessions, pages, goals, corrections, finish dates, reviews and ratings | `~/Library/Application Support/BooksPresence/history.sqlite` and its `-wal`/`-shm` files |
| Imported EPUB copies | `~/Library/Application Support/BooksPresence/Publications/` |
| Bookmarks, highlights, notes and reader appearance | `~/Library/Application Support/BooksPresence/ReaderState/` |
| Imported audiobook copies | `~/Library/Application Support/BooksPresence/Audiobooks/` |
| Cover image cache | `~/Library/Application Support/BooksPresence/Covers/` |
| Single-instance lock | `~/Library/Application Support/BooksPresence/tracker.lock` |
| Settings: goals, time zone, appearance, Discord application ID and asset key, matched public cover links | macOS preferences for `com.bookspresence.app` |

The folder is readable only by your account (permissions `0700`). Exports, backups and
reading-state files are written only where you choose in a save dialog. Normal launches write
no logs containing titles or authors.

## What Stillleaf reads from other apps

- **Apple Books library (Sync finished books, on by default).** Stillleaf opens Apple Books'
  library database read-only to import finish dates. It reads each book's asset ID, title,
  author, file path, finished flag and date, saved progress, page count and store ID. It never
  writes to Apple Books. It also reads Apple Books' book list and each book's cover image and
  metadata files to show covers. You can turn this off in Settings → Data & privacy → Apple Books.
  On macOS 14 and later, macOS may ask whether Stillleaf may "access data from other apps"
  for this.
- **Apple Books reading windows (only if you grant Accessibility).** To credit reading time in
  Apple Books, Stillleaf reads window-level information about the focused Books window:
  - its title, document path, role, size and minimized state;
  - the page indicator in the footer.

  It does not read the text of the book. It does not take screenshots or use OCR, and it does not
  look at other apps' windows.
- **Files you open.** When you import an EPUB or audiobook, Stillleaf copies it into its own
  folder and reads it to display it. Importing a book from Apple Books copies the file Apple
  Books keeps; store purchases are refused.

## Network connections

| Connection | When | What is sent |
|---|---|---|
| **Open Library** search (`openlibrary.org`) | Only while you type at least two characters into the book search when adding a reading record by hand | The words you typed, plus the app name in the User-Agent. Nothing from your library. |
| **Open Library** covers (`covers.openlibrary.org`) | For the search results you are viewing, and when you save a book chosen from them | The cover ID. Open Library may redirect cover requests to the Internet Archive. |
| **Apple iTunes Search** (`itunes.apple.com`) | Only if you turn on both **Share with Discord** and **Find cover art automatically**, for a book not excluded from sharing; at most hourly per book | That book's title and author. The matched public artwork link is passed to Discord; Stillleaf never uploads your local covers. |
| **Discord** (local) | Only with **Share with Discord** on and your own application ID set | Over Discord's local socket on your Mac: the title, author, page or progress, session pages and a public cover link or your asset key. Discord then shows this on your profile. |
| **Update check** (Stillleaf website) | When you choose **Check for Updates…**, or once a day if you turn on **Check automatically** (off by default) | A plain request with the User-Agent `Stillleaf/<version>`. No identifiers, cookies or library data. |
| Links you click | For example the Discord Developer Portal or a release page | Opened in your browser. |

All app requests use ephemeral sessions with no cookies. Like any internet request, each one
reveals your network address to the server it reaches.

The built-in EPUB reader blocks every remote resource. Book scripts cannot run, external links
are not opened, and fonts are bundled. Reading an imported book never touches the network.

## What Stillleaf never does

- No analytics, telemetry, advertising identifiers or third-party SDKs.
- No accounts and no cloud sync. Stillleaf runs no servers that store your data.
- No crash reports sent to the developer. macOS may share crash reports with Apple according to
  your System Settings → Privacy & Security → Analytics choices. Apple does not forward those to
  developers of apps distributed outside the App Store.
- No reading of book text from Apple Books, no screen capture, no keystroke or input monitoring.
  Idle time comes from the system's "seconds since last input" counter, not from your input.

## Permissions macOS may ask for

| Permission | Why | Required? |
|---|---|---|
| Accessibility | Apple Books reading-time capture | Optional. Asked only when you choose to allow it. Reading in Stillleaf works without it. |
| Access data from other apps (macOS 14+) | Reading Apple Books' library for finished-book sync and covers | Optional. Turn off **Sync finished books** to avoid it. |
| Login item | **Open at login** | Optional. Stillleaf turns it on once, the first time it opens from an installed location such as Applications (never from the disk image). Turn it off in Settings or in System Settings → General → Login Items. |

Stillleaf does not use the camera, microphone, contacts, calendars, photos, location,
Bluetooth, screen recording or Apple Events.

## Deleting your data

Settings → Data & privacy → Reset → **Delete reading data…**:

- removes all reading records, managed backups and cached covers;
- moves imported books (with their notes and highlights) and imported audiobooks to the Trash;
- turns off Apple Books sync.

Empty the Trash to finish. Exports and backups you saved elsewhere are yours to delete. Goals,
appearance and Discord settings remain until you uninstall completely (below).

The database uses SQLite secure delete, followed by a checkpoint and vacuum. Copies outside
Stillleaf's control may remain: Time Machine, APFS snapshots, SSD wear-levelling and files you
copied yourself.

## Uninstalling completely

Settings → Data & privacy → Reset → **Uninstall Stillleaf…** turns off Open at login, moves the
app to the Trash and quits. It keeps your reading history in case you reinstall. To remove
everything:

1. In Stillleaf, choose **Delete reading data…** first if you no longer want your history.
2. Choose **Uninstall Stillleaf…**, or quit Stillleaf and drag it from Applications to the
   Trash.
3. Remove the remaining files and permissions in Terminal:

   ```sh
   rm -rf ~/Library/Application\ Support/BooksPresence
   defaults delete com.bookspresence.app
   rm -rf ~/Library/Caches/com.bookspresence.app ~/Library/HTTPStorages/com.bookspresence.app \
          ~/Library/WebKit/com.bookspresence.app ~/Library/Saved\ Application\ State/com.bookspresence.app.savedState
   tccutil reset All com.bookspresence.app
   ```

   Some of these folders may not exist. macOS creates the cache, web and saved-state folders
   only when needed. `tccutil` clears the Accessibility and other-apps-data decisions.
4. Empty the Trash.

Stillleaf installs no background daemon, privileged helper, kernel or system extension, or
launch agent besides the standard login item.

## Contact

Questions about this statement: **[contact address to be published with the website]**.
