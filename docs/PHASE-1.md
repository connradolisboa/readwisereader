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

**Phase 1B metadata browser, search, and selection/download are implemented but
not physically Kindle-verified.** `api/reader.lua` requests Reader list pages with
`withHtmlContent=false`, `withTags=true`, and a 25-item limit, normalizing only
the metadata the UI needs. `ui/browser.lua` provides Browse Reader → Inbox,
Later, and Shortlist plus Search Library, a cursor-driven Load more action,
reusable selection controls, details, and Download Selected. Browsing and search
never fetch document HTML or cover thumbnails. Downloaded markers come from one
per-browser-session scan of the established article/book directories.

The public Reader v3 LIST REST API does not document search. Search therefore
filters metadata locally using Lua-lowercased plain-substring matching over
title, author, site name, summary, and tag names. It scans one 25-document page
per action and exposes Search next page; it is partial until the user reaches the
last page, and it is not full-text search. Results include Inbox, Later,
Shortlist, and Archive documents but exclude Feed and child highlight/note rows.
Non-ASCII text has no Unicode case-folding under Lua 5.1, so use matching case
for those queries.

Tap toggles `[ ]`/`[x]` and long press opens details. Download Selected checks
one session-local ID set, skips already-local items, fetches full HTML by the
documented LIST `id` parameter only now, and feeds each document sequentially to
the existing `downloadDocument` pipeline. A per-document failure is counted and
does not stop the batch. Successful and already-local rows gain `✓` immediately.

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
6. **Done —** use the KOReader touch-menu pattern: tap toggles selection, hold
   opens details, selected count stays visible, and download asks for confirmation.
   Fetch HTML one document at a time and reuse the established writer. Report
   downloaded, existing, skipped, and failed counts; keep collection checkpoints.
7. Keep picker downloads separate from `synchronize()`: no highlight export,
   completion archive, archive cleanup, reconciliation, filter mutation, or
   `last_sync_time` update.
8. **Done —** add metadata-only search using the public LIST endpoint with HTML
   disabled. Scan one cursor page per action and label the UI/documentation so it
   cannot be mistaken for full-text search.

## Files to create

| File | Responsibility |
| --- | --- |
| `readwisereader.koplugin/api/reader.lua` | Metadata list request and response normalization. |
| `readwisereader.koplugin/library/covers.lua` | Temporary binary download and native cover installation. |
| `readwisereader.koplugin/ui/browser.lua` | Shared browse/search rows, selection, details, and selected-download UI. |

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

## Required physical Kindle verification

1. Restart KOReader, open Readwise Reader → Browse Reader → Inbox.
2. Tap two rows and verify `[x]`; long-press one and verify details rather than a toggle.
3. Choose Download selected (2), confirm, and verify both downloads finish sequentially.
4. Verify EPUB-category documents route to Books and other documents to Articles.
5. Verify both files use the established `[rw-id_<id>]` filename convention.
6. Verify metadata sidecars, Reader location collections, and available covers.
7. Return to the list and verify both rows show `✓` without restarting KOReader.
8. Open Search Library, submit an exact article title, and scan additional pages if needed.
9. Run a new search by author.
10. Search a broader keyword known to occur in title, site, summary, or tags.
11. Verify result rows contain no `nil` or empty separators and show location.
12. Use Search next page and verify matches append without downloading HTML or covers.
13. Select multiple search results and verify Download selected count updates.
14. Download them and remain in the search results after the completion summary.
15. Verify Books/Articles routing and filename conventions again.
16. Verify metadata, collections, and covers for the search downloads.
17. Long-press an undownloaded row and use Download; long-press a downloaded row
    and verify details show Downloaded: Yes. (Open is not implemented.)
18. Search nonsense through the final page and verify a clean zero-match state.
19. Disable Wi-Fi, start a new search, and verify a clean network error with Retry.
20. Re-enable Wi-Fi and retry successfully.
21. Select a row already marked `✓`, download it, and verify Already downloaded: 1
    with no full-content refetch or duplicate file.
22. Run normal sync and verify browser downloads do not cause reconciliation,
    archive, or `last_sync_time` regressions.
23. Create/export a new KOReader highlight and verify the existing Readwise export.
24. Test a batch containing one document whose content request fails; verify later
    documents continue and the summary increments Failed.
25. Restart KOReader and verify covers and local documents persist.

## Physical-device questions

- Which KOReader version/build is installed?
- Does tap-toggle plus hold-for-details behave correctly on the installed touch menu?
- Does custom-cover installation refresh CoverBrowser immediately, or require a
  metadata invalidation/restart?
- Can the Kindle TLS stack fetch representative Reader `image_url` resources?

## Related

- [Architecture](ARCHITECTURE.md)
- [Roadmap](ROADMAP.md)
