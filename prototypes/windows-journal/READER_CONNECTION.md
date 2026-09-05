# Windows reader investigation: SumatraPDF saved PDF position

Status: documented feasibility and a locally fixture-tested read-only probe. **No SumatraPDF installation or Windows reader runtime was tested. No automatic integration is enabled in the journal.**

Official [settings storage documentation](https://www.sumatrapdfreader.org/docs/How-we-store-settings) places `SumatraPDF-settings.txt` beside the portable executable or in `%LOCALAPPDATA%\SumatraPDF` for installed copies. A custom `-appdata` directory can override this. The [3.6 settings reference](https://www.sumatrapdfreader.org/settings/settings) describes `FileStates` records with `FilePath`, `PageNo`, `UseDefaultState` and `IsMissing` fields. Sources inspected September 24, 2026.

Inference: a user-approved, read-only adapter could associate a PDF path with a journal book and offer a saved-position update. It cannot infer pages read, time, current foreground reader or attention. Persisted state can remain after a document closes. PDF page indexes may differ from printed page labels; the probe labels its unit explicitly. It excludes EPUB because reflowed positions require different semantics.

## Probe on Windows later

1. Open a known PDF in SumatraPDF, move to a known physical page index and close the reader to allow settings to flush.
2. Copy the settings file somewhere temporary. Do not share the complete file publicly: it can contain local paths and sensitive settings, including saved document decryption material.
3. From this prototype directory:

```powershell
node tools/sumatra-probe.cjs "$env:TEMP\SumatraPDF-settings-copy.txt"
```

The utility reads the explicit file path and prints only PDF document paths, positive saved page indexes and evidence labels. It does not write files, launch readers, extract document contents or change the journal. It uses the documented 3.6 bracket format, rejects malformed/unbalanced structures and duplicate keys, ignores nested Favorites page numbers, skips missing/default-state documents and refuses settings over 8 MiB. Newer syntax may fail closed; do not call an empty or rejected result successful live integration.

4. Repeat at another page. Compare the printed position after closing the reader. Try two PDFs with the same filename in different folders; verify paths remain distinct. Try disabled remembered state and a missing PDF. Record exact reader version and settings syntax.
5. Investigate flush timing separately before suggesting any continuous observation. Never equate the settings file's modification time with a reading session timestamp.

A future adapter needs explicit path-to-book mapping, renamed-file handling, a preview/confirmation for applying saved position, physical-page versus printed-page explanation, and real version-scoped Windows tests. UI Automation or cooperative reader events would be a separate live-tracking investigation. This probe makes no claim about those capabilities.
