# Native managed EPUB removal

API: `EPUBAssetRemoval(directory: URL, trash: TrashOperation = systemTrash)`. Call `remove(publicationID: String, keepingOriginalAt: URL? = nil)` off-main. Returns `EPUBAssetRemovalResult(publicationID, exportedOriginal, trashedDirectory)`. `TrashOperation` is `(URL) throws -> URL`; production uses `FileManager.trashItem`, tests inject a move into a fixture-only folder.

Pass the managed library root, not the edition folder. Keep one controller-level serial queue shared with import/removal and close any reader for the edition first. On success the controller can unregister the imported edition while retaining book history, reviews and annotations as external-only records. This service has no journal access and never knows the external source URL.

Validation requires a lowercase SHA256 ID, symlink-free managed path, expected exact edition children (`original.epub`, `publication.json`, `resources`), bounded consistent receipt, required resources, no symlinks/special files/hardlinks in the resource tree, and a SHA256 original matching the edition ID. Missing assets or unexpected edition data fail without calling Trash. Export requires an existing nonsymlink parent outside the managed root, `.epub` extension, no existing destination, and a byte-hash-verified copy before Trash. It never overwrites a destination. Symlink aliases including `/var` are conservatively rejected; app-owned paths should use their actual nonsymlink location.

A Trash failure after export returns `EPUBAssetRemovalError.trashFailed(message:exportedOriginal:)` so UI can show the saved file location. The existing edition remains usable when Trash reports a failure before moving it. The injectable operation contract is to throw before mutation or return the moved URL; a custom implementation that moves data then throws cannot be rolled back without its destination. Production uses the system Trash operation. No cross-process mutation guarantee is claimed. Export verification failure retains the created export for inspection rather than deleting a potentially concurrently changed user path.

Executed direct compiler smoke in `.build/mac-import`, using synthetic managed fixtures only. PASS: export then fixture-trash, direct fixture-trash, non-overwrite, internal export rejection, traversal/missing edition, resource symlinks/shared hardlinks, unexpected top-level data, symlink root, injected Trash failure preserving export and edition, journal content preservation. No real Trash or user book was touched.

Compile along with the importer/core model using the prior importer handoff commands, then:

```sh
swiftc -I .build/mac-import -L .build/mac-import -lBooksCore -lBooksPlatform scripts/epub-removal-smoke.swift -o .build/mac-import/removal-smoke
.build/mac-import/removal-smoke
```
