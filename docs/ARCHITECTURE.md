# Architecture

## Current implementation

The repository contains `readwisereader.koplugin/main.lua`, focused helper
modules under `api/`, `library/`, and `ui/`, plus `_meta.lua`. There are no
vendored dependencies, tests, fixtures, or KOReader source files in this
checkout.

`ReadwiseReader` is a `WidgetContainer`. `init()` opens
`settings/readwisereader.lua`, initializes state, and registers the menu.
`onDispatcherRegisterActions()` exposes `SynchronizeReadwiseReader`; that event
uses `NetworkMgr:runWhenOnline()` before `synchronize()` runs.

### What `main.lua` currently does

| Area | Main implementation |
| --- | --- |
| Settings | `LuaSettings` stores the access token, directory, filters, sync options, last-sync timestamp, document tag/location maps, author/source URL lookup maps, and the cover URL cache index. |
| Authentication/API | `callAPI()` sends `Authorization: Token <token>` to Reader v3, retries Kindle `wantread`, and handles 429 `Retry-After`. `makeJsonRequest()` posts v2 highlight payloads. |
| Document retrieval | Automatic sync's `getDocumentList()` pages `new`, `later`, and `shortlist` with HTML. `api/reader.lua` separately fetches 25-item metadata-only pages for the browser. `getArchivedDocuments()` pages archive changes. |
| Files/content | `downloadDocument()` writes `[rw-id_<id>] <safe title>.html`, then best-effort applies a Reader cover. `processHtmlContent()` rewrites responsive markup, fetches inline images, base64-embeds them, and applies an image budget. Missing HTML produces a small fallback page. |
| Metadata/sidecars | `setDocumentMetadata()` writes `doc_props` and `custom_props` through `DocSettings.openSettingsFile():flushCustomMetadata(filepath)`, then broadcasts metadata invalidation. |
| Collections | Optional `ReadCollection` maps Reader location to `Readwise: <Location>` and batches writes. |
| Highlights | KOReader history and Kindle My Clippings are parsed; v2 highlights are created with stored author/source URL where possible. |
| Completion/archive | A `.sdr` `summary.status == "complete"` causes PATCH-to-archive then local deletion. Archive cleanup compares remote IDs updated since `last_sync_time`. |
| UI | Nested main-menu tables, `InfoMessage`, `InputDialog`, `ConfirmBox`, `MultiConfirmBox`, `SpinWidget`, and the download-directory picker. Progress is a replaced `InfoMessage`, not a cancelable progress widget. |

### Current local state and risks

There is no database: identity is split across filename prefixes, KOReader
sidecars, collections, and one unversioned settings table. The sync path can
delete local files absent from its filtered server list, so a picker must never
reuse reconciliation. Every downloaded document may flush settings twice for
author/source metadata. HTML conversion is regex-heavy and memory intensive;
leave it stable in Phase 1.

The chief architectural debt is the concentration of transport, Reader mapping,
settings, filesystem work, HTML/images, metadata, collections, highlights,
archive cleanup, and menu UI in one file. Automatic sync still couples its list
requests to full HTML, but the browser and picker use a separate metadata-first
path.

## KOReader integration findings

KOReader source is **not available locally**. The following was checked against
upstream `master`; verify it against the installed Kindle build before coding.

- `DocSettings:flushCustomCover(doc_path, image_file)` copies a cover into the
  normal preferred/fallback sidecar location. It is now called by
  `library/covers.lua` after a Reader image is cached.
- CoverBrowser has mosaic and detailed list modes that consume normal KOReader
  cover/metadata infrastructure. The plugin should not maintain a second mosaic.
- The existing plugin already uses standard menus, dialogs, notification, file
  deletion, collection, sidecar, and persistent-settings APIs.
- No local source was available to verify a reusable multi-select/checkbox list,
  EPUB navigation, or position-jump API. Do not invent one: inspect the target
  KOReader widgets and a bundled complex-list plugin first.

References: [DocSettings custom-cover code](https://github.com/koreader/koreader/blob/master/frontend/docsettings.lua) and [CoverBrowser modes](https://github.com/koreader/koreader/blob/master/plugins/coverbrowser.koplugin/main.lua).

## Reader API capability matrix

| Capability | Status | Notes |
| --- | --- | --- |
| Document list, title, author, source/site, summary, location, reading time, word count | Supported by current code | The list response is used, but not shown in a browser UI. |
| Tags and category | Supported by current code | Used for filters and sidecar keywords. |
| Cover/image URL | Official API, not implemented | List response includes `image_url`; use native custom covers. |
| Full HTML/content | Supported by current code | `withHtmlContent=true`; Phase 1 should request it only per selected download. |
| Original URL | Supported by current code | `source_url` is written to fallback HTML and stored for highlight export. |
| Reading progress retrieval | Official API, not implemented | List response includes `reading_progress`. |
| Reading progress update | Currently blocked | UPDATE documents `seen`, not a percentage/position write. |
| Archive | Supported by current code | PATCH location to `archive`. |
| Move Inbox/Later/Shortlist/Archive | Official API, partly constrained | UPDATE documents `new`, `later`, `archive`, `feed`; shortlist is listable but not documented as writable. |
| Mark seen/unseen | Official API, not implemented | PATCH `seen`; it is boolean. |
| Tags and notes | Official API, not implemented | PATCH replaces tags and a top-level note; notes do not apply to highlights. |
| Highlights Kindle to Readwise | Supported by current code | v2 highlights export; no Reader-document link is created. |
| Highlights Readwise to Kindle | Requires experimentation/private API | No reliable source-location mapping into generated HTML. |
| Daily Digest | Requires experimentation/private API | No documented Reader API endpoint audited. |
| Feed | Official API, not implemented | `feed` is a documented list location. |
| Search | Metadata-only implemented | The public LIST REST API has no search parameter. The plugin filters title, author, site, summary, and tags locally, one 25-document page at a time. Readwise's separate CLI/MCP full-text search is not called from Kindle. |

The public API documents token authentication, paginated list requests,
optional HTML, `image_url`, metadata, `reading_progress`, update fields, tags,
bulk update, and delete. It does not document progress-position writes, Daily
Digest, or search. See [Reader API](https://readwise.io/reader_api).

## Target architecture

Keep `main.lua` as the lifecycle/menu adapter; extract only seams needed by a
feature, not a cosmetic rewrite.

```text
readwisereader.koplugin/
  _meta.lua
  main.lua                     # lifecycle, dispatcher, menu composition
  api/reader.lua               # Reader list/detail/update requests
  api/readwise.lua             # existing v2 highlight request
  library/state.lua            # settings defaults/migration and lookup maps
  library/documents.lua        # file identity and local lookup
  library/covers.lua           # binary fetch + DocSettings custom cover
  sync/documents.lua           # automatic sync orchestration
  sync/highlights.lua          # clipping/export orchestration
  sync/archive.lua             # completion and cleanup
  ui/browser.lua               # browser, search, selection, selected downloads
  ui/settings.lua              # later settings extraction
  util/http.lua                # shared timeout/retry/binary GET policy
```

Phase 1A created `library/covers.lua`. It streams HTTPS covers to
`<download directory>/.readwise/covers/<document-id>.<jpg|png>`, validates JPEG
or PNG signatures, and applies the cached file through `DocSettings`. The
persisted `document_cover_urls` map avoids re-downloading a known usable cover
when an article is re-downloaded; `download_covers` defaults to true.
`api/reader.lua` and `ui/browser.lua` now provide the metadata-only browser,
metadata search, reusable selection, and selected-download flow. Retain the filename
format, `processHtmlContent`, clipping/export, collection calls, archive cleanup,
and existing settings behavior until covered by tests and device verification.

## Phase 1A.1 / 1A.2 implementation notes

`library/paths.lua` is the single document-directory router. `epub` documents
go to `book_directory`; every other supported Reader category goes to
`article_directory`. Both settings fall back to the legacy `directory` value,
and an unset book directory deliberately remains the article directory. Local
ID lookup, completion/archive processing, archive cleanup, reconciliation, and
cover caching enumerate both configured directories, so adding a second folder
does not make existing documents invisible. Directories are created with the
existing `util.makePath` convention at validation time; no files are moved.

### Highlight export audit and behavior

- KOReader annotations are read by `MyClipping:parseHistory()` in
  `parseAllBooks()` after the open document is flushed. On Kindle,
  `parseMyClippings()` is also read and replaces a history entry only when it
  contains more notes. The parsed `booknotes` carries chapter arrays of
  clippings plus its local `file` path.
- `createHighlights()` uses `clipping.text` as Readwise `text` and maps
  `clipping.note` directly to `note`; notes are never concatenated into text.
- Download now stores `reader_metadata[document.id]` in the established Lua
  settings object: id, title, author, source URL, Reader URL, category, site
  name, and image URL when supplied by Reader. Export resolves this by the
  existing `[rw-id_<id>]` filename. Older downloads fall back to the previous
  author and source-URL maps and parsed title.
- Payloads use the documented v2 fields only: text, title, author, source URL,
  image URL, `source_type = "koreader"`, category, note, location,
  location type, and a reliable clipping timestamp. Reader IDs and Reader URLs
  are persisted locally but are not sent because the public create API exposes
  no safe Reader-linkage field.
- KOReader page/XP values are not reliable Reader text anchors for generated
  HTML, so each parsed clipping receives a monotonically increasing integer
  `location` with `location_type = "order"`. This preserves parser reading
  order without claiming native Reader-position synchronization.
- Each annotation is posted independently. A malformed or failed annotation is
  logged with document title and order and does not stop later annotations.
  Readwise performs duplicate protection by title, author, text, and source
  URL; this plugin does not currently retain returned highlight IDs, because a
  create response only groups modified IDs by source and cannot safely map them
  back to individual clippings. No edit or deletion sync is added.

## Phase 1B: metadata browser, search, and selected downloads

`main.lua` owns the menu integration and established authenticated transport.
`api/reader.lua` owns the `/list/` request shape and normalizes each valid API
row into a compact metadata object: id, title, author, site, category, location,
reading time/progress, image and source URLs, summary, update time, and tags.
`ui/browser.lua` owns the text-first KOReader menu rows and information view.

Browse Reader exposes only Inbox (`new`), Later (`later`), and Shortlist
(`shortlist`). Each location loads its first 25 metadata-only entries with
`withHtmlContent=false`, retaining only browser-session pages. A `Load more`
row fetches the next Reader cursor page on demand; it never preloads the full
library. Rows show title and the available author-or-site, reading time, and
display-only progress. The details message shows available metadata, tags,
summary, and local downloaded status.

The downloaded marker is built once per browser session by scanning the existing
centralized article/book directories and matching the established filename ID;
there is no per-row filesystem scan and no metadata database. Browser errors
are non-fatal: missing tokens, network failures, malformed rows, empty locations,
and HTTP failures show a message and leave normal local reading and sync paths
unchanged. Metadata browsing/search does not render thumbnails, fetch HTML,
create files, change Reader state, or synchronize progress.

Search Library uses KOReader's native `InputDialog`. The public v3 LIST REST API
has no documented query parameter, so this is deliberately metadata-only search,
not Reader full-text search. Each Search/Search next page action requests at most
one 25-item metadata page with HTML disabled, retains only matches, and checks
Lua-lowercased plain substrings in title, author, site, summary, and tag names.
Results are limited to Inbox, Later, Shortlist, and Archive; Feed documents and
child highlight/note rows are ignored. Search location is shown in result rows.
Lua 5.1 has no Unicode case-folding here, so non-ASCII searches are reliably
exact-case only.

The same document-list builder now supplies selection to Inbox, Later,
Shortlist, and search results. A tap toggles `[ ]`/`[x]`; a long press opens
details so normal taps are unambiguous. Select all, Clear selection, and Download
selected controls are standard touch-menu entries. Details for a document not
yet local offer Download. Direct Open and Delete local copy remain omitted until
the installed KOReader build provides a verified safe file-opening and complete
sidecar/collection removal pattern.

Selected download first builds one local-ID lookup. Already-local documents are
reported without fetching content. Each remaining ID is retrieved sequentially
through documented `GET /list/?id=...&withHtmlContent=true`, then passed to the
existing `downloadDocument` writer. That preserves centralized Books/Articles
routing, filenames, inline-image handling, covers, metadata sidecars,
collections, and highlight identity. One failed detail request or writer call is
counted and does not abort later items. Successful/already-local IDs update the
session lookup immediately; no per-item directory rescan is performed. Picker
downloads never run automatic reconciliation, archive actions, highlight export,
filter mutation, or `last_sync_time` updates.

## Related

- [Phase 1 implementation plan](PHASE-1.md)
- [Roadmap](ROADMAP.md)
