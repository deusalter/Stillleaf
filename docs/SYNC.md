# Sync between your devices

Stop reading on the Mac, pick up the iPhone, and continue the same book at the
same place, with the same highlights and the same journal.

Sync goes through **a folder the reader chooses**, such as one in iCloud Drive.
There is no Stillleaf server and no account. Whatever keeps that folder the same
on each device (iCloud Drive, or any other file syncing) carries the data, in the
reader's own storage. The apps themselves make no network requests for it.

It is off until a folder is chosen: **Settings → Data & privacy → Your devices** on the
Mac, **Settings → Sync** on iPhone and iPad. Choose the same folder on each device.

## What crosses

| | How it merges |
| --- | --- |
| Books (EPUB files) | Copied into the folder under the hash of their bytes, so a book imported on one device appears on the others. |
| Reading history | Every device's sessions, pages, goals, finishes, ratings and reviews are combined. |
| Place in a book | Wherever the book was read most recently. |
| Bookmarks and highlights | Kept from every device. The newer version of a highlight wins. Removing one removes it everywhere. |
| Deleting a session or a book | Deleted on every device. |
| Appearance (theme, type, size) | Never synced: a phone and a Mac want different pages. |
| Audiobook files, covers chosen by hand | Not synced. A book's history still is. |

## When it runs

- **iPhone and iPad:** when the app comes forward, when it leaves, and when a book
  is closed. Nothing runs in the background. Leaving with a book still open
  publishes the place, highlights and reading so far (`FolderSync.publish`)
  without taking anything in; the full pass follows when the book is closed.
- **Mac:** when the library has loaded at launch, when the journal changes or the
  Mac is returned to (at most once a minute), and on **Sync now**.

A pass waits while reading is being recorded, and a book that is open in a reader
is published but not written to, because the reader would write over it. How
quickly a change reaches the other device then depends on the folder's own
syncing, usually well under a minute on iCloud Drive.

## The folder

```
<folder>/stillleaf-sync.json                    what this folder is, and its format version
<folder>/devices/<device id>/device.json        the device's name
<folder>/devices/<device id>/journal.json       its whole journal, in the JSON export format
<folder>/devices/<device id>/tombstones.json    what it has deleted
<folder>/devices/<device id>/reader/<edition>.json   its place, bookmarks and highlights in a book
<folder>/books/<edition>.epub                   the books
```

**Each device writes only inside its own `devices/<id>` folder.** Two devices
never write the same file, so the folder's syncing has nothing to reconcile and
cannot produce "conflicted copy" files. Book files are named by the SHA-256 of
their bytes, so two devices adding the same book write identical files.

Files are written whole (atomically), and a file that has not changed is not
rewritten. A file iCloud has not downloaded to this device yet is asked for and
read on the next pass.

## How the journal merges

The journal is append-only with unique ids, so merging is a union. Three things
need a rule (`ReadingStore.mergeSynced`):

- **Overlapping time.** The journal refuses two sessions that cover the same
  minutes. If two devices recorded reading at the same time, each keeps its own
  session and leaves the other's out. Totals can differ by that session between
  devices; nothing is double counted.
- **The same session edited on two devices.** Each device keeps its own edit.
- **A book both devices know.** Each keeps its own record of it, because cover
  and audio file paths belong to a device. New books arrive without those paths.

An unchanged journal from another device is recognised by its digest and skipped,
so an idle pass never touches the journal or stops the tracker.

## Deletions

The journal deletes for real: a deleted session leaves nothing behind. Without a
record of the deletion, the next sync would bring it back from another device. So
each device keeps **tombstones** (`SyncTombstones`): the ids it deleted and when.

- Rows a tombstone covers are ignored when another device's journal is merged.
- Another device's tombstones are applied locally, then passed on.
- A book's tombstone stops applying once the book is observed again after the
  deletion, so importing the same file later is a fresh start: its history
  crosses again and so does its file, including to the devices that had deleted it.
- Tombstones are kept for 400 days.

Deletions are noted in the device's own memory file at the moment they happen,
so they are not lost if the folder is unreachable at that moment. They are noted
while sync is turned off too, once a device has ever synced, so turning sync back
on does not hand back what was deleted in between.

Two things are deliberately **not** deletions everywhere:

- **Remove EPUB from this device** keeps the history and keeps the book on the
  other devices. This device remembers not to fetch it again.
- **Delete all data** turns sync off on that device and takes that device's own
  folder (`devices/<id>`) out of the sync folder, so no copy of the deleted
  journal stays in the reader's cloud storage. It does not delete the journal on
  the other devices; choosing the same folder again brings their history back.

Restoring a backup replaces the journal, so the device forgets which journals it
had already merged and merges every other device's journal afresh.

## Reader state

`ReaderStateSync.merge` works on the reader's own state document:

- The place comes with the time the reading happened, carried from device to
  device. A device that syncs without having read does not present an old place
  as new.
- Bookmarks and highlights merge by id. Each device remembers which it held at
  the last pass, so it can tell "removed here" from "never arrived here".
- The merged document gets a revision above every one seen, so the reader
  accepts it, and it is checked with `ReaderStateValidation` before it is saved.
- A book whose state cannot be saved is reported and skipped; the rest of the
  pass, and the publishing after it, still happen.

## Code

| Where | What |
| --- | --- |
| `Sources/BooksCore/SyncTombstones.swift` | Tombstones, and the report of what a merge did |
| `Sources/BooksCore/ReadingStore.swift` (`mergeSynced`) | The tolerant journal merge |
| `Sources/BooksCore/ReaderStateSync.swift` | Reader state records and their merge |
| `Sources/BooksPlatform/FolderSync.swift` | The folder layout and one whole pass (`sync`) |
| `Sources/BooksPresence/AppModel.swift` (Sync section) | The Mac's triggers, folder choice and hooks |
| `iOS/Stillleaf/Model/Journal.swift` (Sync section) | The same for iPhone and iPad |

The engine is shared, so both apps follow the same rules.

## Checks

- `Tests/BooksPlatformTests/FolderSyncScenario.swift`: two devices through one
  folder, covering every rule above. It runs as an XCTest (`FolderSyncTests`)
  and, on Macs without XCTest, as `scripts/sync-smoke.swift` in
  `scripts/check-local.sh`.
- `iOS/StillleafTests/JournalSyncTests.swift`: two iOS journals through one
  folder: triggers, a book arriving, a deletion crossing.

## Not verified, and known limits

- **Real iCloud Drive between a real Mac and iPhone has not been tried.** The
  tests use a local folder that both sides see at once. Download placeholders,
  delays and iOS folder access through a security-scoped bookmark are handled in
  code but have not run on devices.
- Sessions that overlap in time across devices are left out on the other device
  rather than reconciled.
- A book's deletion is compared with when each device last recorded the book, by
  each device's own clock. Clocks that disagree by more than the gap between the
  two events can let a deleted book survive, or delete one imported again
  moments later. A book that another device changes (opens and counts its pages,
  say) after it was deleted elsewhere, before that device has synced, also
  survives.
- A restore or an archive import that brings back a session deleted while sync
  was on will have it deleted again by the next pass: a session's deletion is
  permanent for 400 days.
- A book deleted while the folder is out of reach (or sync is off) leaves its
  file in `books/`; no device fetches it, but it is not cleaned up.
- Book metadata (title, author) edited on one device does not propagate.
- A daily goal changed on two devices for the same day can resolve differently
  on each.
- Files are read and written without `NSFileCoordinator`. This is safe because
  no file has two writers, but a read can see a file mid-download; it is then
  skipped and read on the next pass.
- CloudKit would give near-instant sync with no folder to choose. It needs the
  paid Apple Developer Program and would reuse the merge rules above with a
  different transport.
