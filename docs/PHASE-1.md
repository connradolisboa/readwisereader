# Phase 1: covers and article picker

## Scope and implementation status

Add an explicit Reader browse/download path and best-effort custom covers. Do
not replace automatic sync, alter archive/highlight semantics, add a database,
or claim reading-progress write-back.

**Phase 1A covers is implemented and physically Kindle-verified.**
`library/covers.lua` streams HTTPS Reader `image_url` values to
`<download directory>/.readwise/covers/<document-id>.<jpg|png>`. It accepts only
non-empty JPEG and PNG responses whose Content-Type and file signature agree,
then calls `DocSettings.openSettingsFile():flushCustomCover(document_path,
cache_path)`. The existing metadata write follows it and broadcasts the existing
metadata invalidation events. Failures are logged and cannot fail article,
metadata, or collection creation. `download_covers` is a new backward-compatible
setting that defaults to true; `document_cover_urls` records the URL used for a
cache hit if the article is later re-downloaded. WebP, AVIF, GIF, SVG, missing/mismatched Content-Type,
non-HTTPS URLs, and covers larger than 5 MB are deliberately skipped.

**Phase 1B Part 1 metadata browser is implemented but not physically
Kindle-verified.** `api/reader.lua` requests Reader list pages with
`withHtmlContent=false`, `withTags=true`, and a 25-item limit, normalizing only
the metadata the UI needs. `ui/browser.lua` provides Browse Reader → Inbox,
Later, and Shortlist with text-first rows, an InfoMessage details view, and a
cursor-driven Load more item. It does not download documents, render covers,
persist metadata, alter Reader state, or run sync/reconciliation. Downloaded
markers come from one per-browser-session scan of the established article/book
directories.

## Exact build order

1. Characterize the physical Kindle's KOReader version. Confirm
   `DocSettings:flushCustomCover` and inspect the installed widgets/bundled
   plugins for a compatible multi-select or checkbox-list implementation.
2. Create `api/reader.lua`; move the authenticated request, timeout/retry,
   JSON-null normalization, and pagination seam behind adapters. Provide a
   metadata list (`withHtmlContent=false`, bounded page size) and a detail fetch
   by `id` with `withHtmlContent=true`.
3. **Done —** `library/covers.lua` downloads a valid HTTPS `image_url` to a
   temporary hidden-cache path, validates it, atomically promotes it to a
   document-ID cache filename, calls `DocSettings.openSettingsFile():flushCustomCover`,
   and cleans temporary files. Cover errors only log; they never roll back a
   successful article download.
4. **Done —** the cover service runs after the HTML file exists and before the
   established metadata/collection steps. Inline article images remain separate
   and covers are never base64-embedded.
5. **Done —** create `api/reader.lua` and `ui/browser.lua`, then add “Browse
   Reader” with Inbox, Later, and Shortlist. Fetch metadata only, render
   title-first text rows, and load additional cursor pages only on demand.
6. Part 2: use the verified KOReader multi-selection pattern, show selected count, ask
   for Download confirmation, fetch HTML one document at a time, and reuse the
   established document writer. Report downloaded, existing, skipped, and failed
   counts; keep collection save checkpoints.
7. Keep picker downloads separate from `synchronize()`: no highlight export,
   completion archive, archive cleanup, reconciliation, filter mutation, or
   `last_sync_time` update.

## Files to create

| File | Responsibility |
| --- | --- |
| `readwisereader.koplugin/api/reader.lua` | Metadata list request and response normalization. |
| `readwisereader.koplugin/library/covers.lua` | Temporary binary download and native cover installation. |
| `readwisereader.koplugin/ui/browser.lua` | Metadata location browser, cursor pages, rows, and details. |
| `readwisereader.koplugin/ui/picker.lua` | Future selection/download workflow. |

## Existing functions: move later or leave untouched

- Move `callAPI`, `checkRateLimit`, `handleRetryAfter`, and JSON normalization
  first, retaining adapters for current callers.
- Move `getDocumentList` and sync orchestration only after automatic-sync
  regression coverage exists.
- Keep `downloadDocument` as the shared content-to-file seam until a narrow
  writer is independently verified.
- Leave `processHtmlContent`, responsive image extraction, URL repair, inline
  image download, clipping parsing/export, completion archive, cleanup,
  collections, settings keys, filename ID encoding, and settings UI untouched.

## Regression protection

- Every existing `readwisereader` setting key stays readable with its present
  default; new state is optional and default-empty.
- Preserve `[rw-id_<id>]` filenames for lookup, cleanup, and highlight metadata.
- Bound cover timeout/size and make it non-fatal; do not reuse the article image
  budget until an explicit cover limit is chosen.
- Download sequentially and discard HTML per document to respect rate limits and
  Kindle memory.
- Picker code never triggers destructive reconciliation.
- Add small pure-Lua tests/fixtures for request construction, ID parsing, and
  result aggregation if a KOReader-compatible harness is selected. No harness
  exists in this repository now.

## Required manual verification

1. Run LuaJIT syntax/lint checks against the target KOReader release.
2. With CoverBrowser enabled, verify a downloaded JPEG/PNG `image_url` appears
   in mosaic and detailed-list modes after the required refresh/restart.
3. Verify no-image and unreachable-image documents still create HTML, metadata,
   and collections without crashing.
4. Browse all three locations; select one/many, cancel once, then download and
   confirm that only selected IDs are written.
5. Disable network after download; local articles must open, and network errors
   must leave state intact.
6. Re-run automatic sync, finished archive, archived cleanup, and highlight
   export with existing files; check collections, sidecars, filename matching,
   and settings.
7. Restart KOReader and verify the custom cover persists. To exercise cache reuse
   without adding a re-download feature, remove a test article's local HTML file
   while retaining `.readwise/covers/`, then sync and verify a cache-hit log
   rather than another network download. Finally test a low-memory Kindle with
   image-heavy content and slow/failing covers.

### Phase 1B Part 1 browser verification

1. Restart KOReader, open Readwise Reader, then Browse Reader.
2. Open Inbox and verify the metadata page loads without creating an HTML file.
3. Scroll through at least 20–30 entries and check title/author-or-site text.
4. Check reading-time and percentage formatting, including rows with missing values.
5. Confirm existing local documents have a `✓` marker and undiscovered ones do not.
6. Open a document details message, verify available title, author, site, category,
   location, reading time, progress, tags, summary, and Downloaded fields, then close it.
7. Use Load more when available and confirm the next page appends without duplicate rows.
8. Return to the location list, test Later and Shortlist, and test an empty location.
9. Disable Wi-Fi, reopen Browse Reader, and verify a useful error rather than a crash.
10. Re-enable Wi-Fi, verify existing downloaded articles still open, then run normal
    sync and re-check covers, collections, cleanup, and highlight export.

## Physical-device questions

- Which KOReader version/build is installed?
- Which verified multi-select/checkbox widget pattern is available there?
- Does custom-cover installation refresh CoverBrowser immediately, or require a
  metadata invalidation/restart?
- Can the Kindle TLS stack fetch representative Reader `image_url` resources?

## Related

- [Architecture](ARCHITECTURE.md)
- [Roadmap](ROADMAP.md)
