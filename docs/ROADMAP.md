# Roadmap

This is an incremental product plan. Existing automatic sync, completion archive,
and Kindle-to-Readwise highlight export remain in place throughout.

## Phase 1: native covers, library search, and selected downloads

- **Part 1 implemented, not Kindle-verified:** a metadata-only Reader browser
  for Inbox (`new`), Later, and Shortlist. It uses 25-item cursor pages, shows
  text-first metadata and local downloaded state, and never fetches HTML.
- **Part 2 implemented, not Kindle-verified:** reusable selection for those
  browser lists and metadata-only search across Library locations. Tap toggles a
  row, hold opens details, and Download Selected runs sequentially.
- Search scans one 25-document public LIST page at a time and filters title,
  author, site, summary, and tags locally. It is not full-text search; Load more
  explicitly scans the next page. Feed documents are included; child
  highlight/note documents are excluded from search results. Non-ASCII
  matching is exact-case because Lua 5.1 has no Unicode case-folding in this
  path.
- **Implemented:** Views (Quick Reads, Long Reads, In Progress) reproduce
  Readwise Reader's own smart views locally, since the public API documents no
  such filter. They scan Inbox/Later/Shortlist/Archive metadata the same way
  search does and threshold `reading_time`/`reading_progress`; Feed is excluded.
  Picking a view only narrows what is shown -- selection and download work the
  same as any other browser list.
- **Implemented, read-only:** a Highlights menu separate from the existing
  export pipeline, backed by `api/highlights_read.lua`: Search Highlights scans
  v2 `GET /highlights/` one page at a time and filters text/note locally (no
  documented full-text query parameter exists there either), fetching a
  highlight's book title/author lazily only when its details are opened. Daily
  Review calls the documented `GET /review/` endpoint directly.
- Full HTML is fetched by the documented LIST `id` parameter only for selected
  documents, then passed to the existing downloader.
- Fetch `image_url` best-effort and install it with `DocSettings:flushCustomCover`
  so bundled CoverBrowser modes can use it.
- Preserve existing automatic sync and settings/filename conventions. Browser
  pages are online-only session state; no offline metadata cache yet.

See [the detailed Phase 1 plan](PHASE-1.md).

## Phase 2: library quality and local operations

- Persist a compact metadata cache for offline picker browsing only if settings
  storage is measured to be inadequate.
- Browse Archive, Feed, tags, and categories; add site, time, local state, and
  Reader progress to rows without downloading HTML for the entire list.
- Improve safe local-copy removal plus collection/sidecar cleanup.
- Evaluate documented Reader actions: archive, seen/unseen, tags, notes, and bulk
  update. Verify Shortlist writes with the public API before exposing them.

## Phase 3: reading workflow improvements

- **Implemented, not Kindle-verified:** clearly-labelled approximate progress
  mapping from Reader to the device, off by default under "Start at Readwise
  Reader position". A document is moved only when Reader was opened since the
  last check, is more than a 2% dead band ahead of the sidecar's
  `percent_finished`, and was opened in Reader more recently than the sidecar was
  written -- so a tie goes to the device and local reading is never overwritten.
  The jump is applied once, on open, through a `GotoPercent` event. See
  [Architecture](ARCHITECTURE.md).
- Determine whether KOReader reading state can map usefully to generated HTML.
- Investigate a Daily Digest EPUB only after a supported data source and
  Kindle-native EPUB workflow are confirmed.
- Improve content/image conversion and offline recovery.
- Explore Reader-to-Kindle highlights only with a stable source-location model.

## Known API limitations

- **There is no public write path for Reader-anchored highlights.** Verified
  2026-08-31 against both surfaces. The documented Reader REST API exposes only
  `save`, `list`, `update`, `bulk_update`, `delete` and `tags` -- no highlight
  CREATE. Readwise's public MCP server (`https://mcp.readwise.io/sse`, OAuth via
  `https://readwise.io/o/authorize/`) answers `tools/list` with exactly two
  tools, `search` and `fetch`, and describes itself as providing "search and
  retrieval capabilities ... for Chat and Deep Research". A
  `reader_create_highlight` operation exists in Readwise's first-party
  integration with some chat clients, but it is not reachable from this plugin
  and must not be planned against. Re-check before revisiting Reader anchoring.
- v2 highlight CREATE de-dupes on `title`/`author`/`text`/`source_url`, so
  re-sending an unchanged highlight is a no-op server-side. An *edited* one is a
  new highlight unless it carries a stable `highlight_url`, which the endpoint
  treats as an update key.
- The v2 CREATE response returns each affected book with a `modified_highlights`
  array, which is the only trustworthy count of what actually landed.

- **Reading position cannot be sent to Reader.** Verified 2026-08-31. Public
  list data includes `reading_progress`, but UPDATE and `bulk_update` accept only
  `title`, `author`, `summary`, `language`, `published_date`, `image_url`,
  `seen`, `location`, `category`, `tags` and `notes`. There is no percentage,
  position, offset or scroll field, and `seen` is boolean rather than a progress
  substitute. Completion-to-archive remains the only device-to-Reader signal, so
  progress support is Reader-to-device only.
- **Local files cannot be uploaded to Reader.** Verified 2026-08-31. `save`
  accepts `url` (required) and `html`; there is no file-upload field and no
  multipart endpoint. EPUB, PDF and Markdown upload is web-drag-drop and
  mobile-share-sheet only. An EPUB already on the device therefore cannot be
  pushed to Reader and kept in sync. Converting one to HTML and posting it to
  `save` would create an *article* with a second identity for a file the device
  already holds, so it is deliberately not done. Highlights from local books do
  reach Readwise through the existing v2 export.
- Documented writable locations are `new`, `later`, `archive`, and `feed`;
  Shortlist is listable but not documented as writable.
- No public Reader HTTP endpoint was found for Daily Digest or document search.
- Exported highlights have no reliable reciprocal location map into generated HTML.

## Experimental future features

- Multi-article Daily Digest EPUB.
- True full-text search via a future documented REST endpoint, for both the
  Reader library and highlights. The public MCP server's `search` tool covers
  highlights rather than the Reader library, and its OAuth flow is not
  something this plugin can drive on device, so it is not a shortcut here;
  local metadata/text-only scanning (implemented above) remains the fallback.
- Joining highlight search results to their book's title/author without a
  per-highlight `GET /books/<id>/` fetch, if v2 ever documents an embed/expand
  parameter.
- Reader-to-Kindle highlight import.
- Generated fallback covers for documents without `image_url`.

## Related

- [Architecture](ARCHITECTURE.md)
- [Phase 1 implementation plan](PHASE-1.md)
