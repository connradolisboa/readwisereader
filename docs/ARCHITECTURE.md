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
| Settings | `LuaSettings` stores the access token, directory, filters, sync options, last-sync timestamp, document tag/location maps, author/source URL lookup maps, cover URL cache index, and explicit local-file-to-Reader links. |
| Authentication/API | `callAPI()` sends `Authorization: Token <token>` to Reader v3, retries Kindle `wantread`, and handles 429 `Retry-After`. `makeJsonRequest()` posts v2 highlight payloads. |
| Document retrieval | Automatic sync's `getDocumentList()` pages `new`, `later`, and `shortlist` with HTML. `api/reader.lua` separately fetches 25-item metadata-only pages for the browser. `getArchivedDocuments()` pages archive changes. |
| Files/content | `downloadDocument()` writes `[rw-id_<id>] <safe title>.html`, then best-effort applies a Reader cover. `processHtmlContent()` rewrites responsive markup, fetches inline images, base64-embeds them, and applies an image budget. Missing HTML produces a small fallback page. |
| Metadata/sidecars | `setDocumentMetadata()` writes `doc_props` and `custom_props` through `DocSettings.openSettingsFile():flushCustomMetadata(filepath)`, then broadcasts metadata invalidation. |
| Collections | Optional `ReadCollection` maps Reader location to `Readwise: <Location>` and batches writes. |
| Highlights | KOReader history and Kindle My Clippings are parsed. `buildHighlightContext()` resolves the book-level fields from a downloaded Reader record or an explicit exact-local-path link; `api/highlights.lua` builds the payloads, batches them 100 per request, and reports what the server confirmed via `modified_highlights`. |
| Completion/archive | A `.sdr` `summary.status == "complete"` causes PATCH-to-archive then local deletion. Archive cleanup compares remote IDs updated since `last_sync_time`. |
| UI | Nested main-menu tables, `InfoMessage`, `InputDialog`, `ConfirmBox`, `MultiConfirmBox`, `SpinWidget`, and the download-directory picker. Downloads show `ui/downloadprogress.lua`: a real progress bar with counts, bytes, and a Cancel button. Other long steps still use a replaced `InfoMessage`. |

### Current local state and risks

There is no database: identity is split across filename prefixes, KOReader
sidecars, collections, and one unversioned settings table. The sync path can
delete local files absent from its filtered server list, so a picker must never
reuse reconciliation. Every downloaded document may flush settings twice for
author/source metadata. HTML conversion is regex-heavy and memory intensive;
leave it stable in Phase 1.

### Local-book Reader links

`library/local_links.lua` persists a compact Reader metadata record against the
exact path of a local KOReader book. **Link current book to Reader…** uses the
existing metadata-only Reader search and requires the user to choose a result;
the filename is never an identity match. No HTML is fetched for this operation.

On export, an explicit link supplies the Reader title, author, source URL,
category, image URL, and Reader URL. The latter provides a stable
`highlight_url` base. The v2 highlight API has no Reader-document ID field, so
this is grouping metadata, not a guaranteed attached Reader highlight. Moving
or renaming the local file invalidates its path-keyed link, and My Clippings
records without a local file cannot resolve one.

### Save link to Reader

**Implemented, not Kindle-verified:** built against upstream KOReader
`master`'s `readerlink.lua` and `ui/network/manager.lua` (no local KOReader
checkout in this repo -- see "KOReader integration findings" above); confirm
`addToExternalLinkDialog`, `onNetworkConnected`, and `NetworkMgr:isOnline()`
behave as documented on an installed build before relying on it.

`registerExternalLinkAction()` (called once from `init()`, guarded on
`self.ui.link` so it only runs in the ReaderUI instance, never FileManager)
adds a button to KOReader's own external-link dialog through
`ReaderLink:addToExternalLinkDialog`, the same public extension point core
buttons like Copy and Show QR code use. Tapping a link keeps KOReader's
existing Copy/QR/Open-in-browser/Cancel options and adds "Save to Readwise
Later", which posts the tapped href -- not the visible link text -- so it
works even when the link text itself isn't a URL.

`saveLinkToReadwiseLater()` checks `NetworkMgr:isOnline()`, which only reports
current status and never prompts to connect. Online, it posts immediately
through `sendLinkToReader()`. Offline, or on a failed request, it calls
`queueLinkSave()`, which appends to `pending_link_saves` (deduplicated by URL)
and persists it through the existing settings object. Queued links are
retried, without interrupting reading, from two triggers: `onNetworkConnected`
(KOReader's broadcast event when the network reconnects) and the start of
`synchronize()` once settings are validated and online is confirmed. Advanced
sync also exposes a manual "Send queued links to Readwise Later" action,
enabled only when the queue is non-empty, for an explicit retry with a result
message either way.

### Manual linked-book progress

The **Linked book progress** submenu is manual and only available for the open
local book with an explicit Reader link. Sending reads KOReader's existing
`percent_finished` sidecar, fetches linked Reader metadata with HTML disabled,
and replaces only a visible, HTML-comment-marked `KOReader progress: N%` line in its
top-level `notes` field. It preserves the rest of the Reader note and removal
is confirmed before patching the document.

Applying the Reader percentage fetches `reading_progress` and dispatches the
existing `GotoPercent` event only after confirmation. It is deliberately not a
background or bidirectional sync: Reader offers no progress write field, and
the two readers paginate different renderings.

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
| Reading progress retrieval | Supported by current code | List returns `reading_progress` (0-1) plus `first_opened_at`, `last_opened_at`, `saved_at`, and `last_moved_at`. `library/progress.lua` decides when to move the device; `percent_finished` and a `GotoPercent` event apply it. |
| Reading progress update | Currently blocked | Verified 2026-08-31: UPDATE and `bulk_update` accept only `title`, `author`, `summary`, `language`, `published_date`, `image_url`, `seen`, `location`, `category`, `tags`, `notes`. No percentage, position, offset, or scroll field, and `seen` is boolean. Completion-to-archive stays the only device-to-Reader signal. |
| Local file upload to Reader | Not available | Verified 2026-08-31: `save` accepts `url` (required) and `html`, with no file-upload field and no multipart endpoint. EPUB/PDF/Markdown upload is web and mobile UI only, so a book already on the device cannot be pushed to Reader. |
| Save a URL to Reader | Supported by current code | `POST /save/` with `url` and `location = "later"`. Verified 2026-09-16: the endpoint returns `201` (created) or `200` (document already existed); `callAPI` treats both as success. Exposed as "Save to Readwise Later" in the reader's external-link dialog. |
| Archive | Supported by current code | PATCH location to `archive`. |
| Move Inbox/Later/Shortlist/Archive | Official API, partly constrained | UPDATE documents `new`, `later`, `archive`, `feed`; shortlist is listable but not documented as writable. |
| Mark seen/unseen | Official API, not implemented | PATCH `seen`; it is boolean. |
| Tags and notes | Official API, not implemented | PATCH replaces tags and a top-level note; notes do not apply to highlights. |
| Highlights Kindle to Readwise | Supported by current code | v2 highlights export; no Reader-document link is created. |
| Highlights Readwise to Kindle | Requires experimentation/private API | No reliable source-location mapping into generated HTML. |
| Daily Digest | Requires experimentation/private API | No documented Reader API endpoint audited. |
| Feed | Search implemented; browsing not implemented | `feed` is a documented list location. Library search scans it; the location is not yet one of the Browse Reader tabs. |
| Search | Metadata-only implemented | The public LIST REST API has no search parameter. The plugin filters title, author, site, summary, and tags locally, one 25-document page at a time, across Inbox/Later/Shortlist/Archive/Feed. Readwise's separate CLI/MCP full-text search is not called from Kindle. |
| Views (Quick Reads / Long Reads / In Progress) | Implemented locally | Not a documented API filter. Reproduced by scanning Library metadata (Inbox/Later/Shortlist/Archive, Feed excluded) the same way search does, thresholding the existing `reading_time`/`reading_progress` fields (`<=5 min`, `>=20 min`, `0 < progress < 1`). See `api/reader.lua`'s `viewMetadata`. |
| Highlights listing/search | Read-only, implemented | v2 `GET /highlights/` is paginated but has no documented full-text query parameter, so `api/highlights_read.lua` scans one page at a time and filters text/note locally, mirroring Reader metadata search. A highlight's book title/author is fetched lazily via `GET /books/<id>/` only when its details are opened. |
| Daily Review | Read-only, implemented | v2 `GET /review/` returns today's review highlights directly, each already carrying its own title/author. |

The public API documents token authentication, paginated list requests,
optional HTML, `image_url`, metadata, `reading_progress`, update fields, tags,
bulk update, and delete. It does not document progress-position writes, file
uploads, Daily Digest, or search. See [Reader API](https://readwise.io/reader_api).

## Download progress and cancellation

`ui/downloadprogress.lua` is the cancelable download dialog used by both the
sync loop and the picker's selected-download flow. It shows a title, an
"N of M / K remaining" headline, a `ProgressWidget` bar over completed
documents, the current article's title, cumulative bytes fetched, and a Cancel
button.

It does not use KOReader's stock `ProgressbarDialog`: that widget only arrived
in mid-2025 and may be missing from an installed Kindle build, its texts are
fixed at construction, and it cancels by tapping anywhere rather than with a
button. This dialog is assembled from `ProgressWidget`, `TextWidget`, `Button`
and the standard containers, all of which have been in KOReader since 2013-2017.
Construction is wrapped in `pcall`; if it fails, both loops fall back to the
existing `showProgress` messages and simply run without a Cancel control.

**Cancellation requires a coroutine.** A download loop blocks, so UIManager
never gets to dispatch a Cancel tap. Following the pattern in KOReader's OTA
updater, each `update()` schedules a resume on the next tick and yields; the
Cancel button resumes early with the cancelled flag set. `synchronize()`
re-enters itself through `Trapper:wrap` when it is not already in a coroutine,
and `Browser:download` wraps the whole picker download -- including result
handling, because the wrapped call returns at the first yield, so anything left
outside the wrap would run before the download finished.

**`tick()` versus `update()`.** LuaJIT cannot yield across a C-call boundary,
and image fetching happens inside `string.gsub` callbacks in
`processHtmlContent`. `update()` redraws *and* yields and must only be called
between documents; `tick()` (and `addBytes`, which it backs) only redraws and is
what `fetchAndEncodeImageWithSize` calls. So byte totals keep moving during a
long image-heavy article, but a Cancel press takes effect at the next document
boundary rather than mid-article.

Bytes reported are what came over the wire -- the article HTML plus each image's
raw response -- not the inflated base64 or the final file size. No total size is
predicted: base64 embedding and the image budget make an upfront estimate from
the HTML alone badly wrong, so the bar tracks document count instead.

Cancelling stops before the current document is written, so no partial file is
left behind, and everything already downloaded is kept. A cancelled sync
deliberately does not advance `last_sync_time`, so the next archive-cleanup pass
still reasons from the last complete sync.

## Reading progress

Progress is one-way by necessity: Reader publishes `reading_progress` but offers
no field to write a position to, so nothing is ever pushed back. The feature is
off by default under `sync_reading_progress` and is presented as approximate,
because Reader measures progress over its own rendering while KOReader paginates
the HTML `processHtmlContent` generates.

`library/progress.lua` holds the whole policy as a pure function so it can be
tested without KOReader, matching the `paths.lua` (pure, tested) and
`covers.lua` (I/O, not tested) split. Sidecar reads and writes stay in
`main.lua` beside the existing `DocSettings` completion code.

`Progress.decide` seeds only when Reader's progress is between 1% and 100%, the
document was opened in Reader since the previous check (`last_opened_at`),
Reader is more than a 2% dead band ahead of the sidecar's `percent_finished`,
and the sidecar's mtime is older than Reader's `last_opened_at`. That last rule
makes the device win a tie, so reading on the Kindle is never overwritten by a
stale Reader position. ISO 8601 values are parsed to epoch seconds rather than
compared as strings, because they are also compared against filesystem mtimes
and Reader is not contractually stable about fractional seconds or zone format.

Two paths record a seed: `downloadDocument` on a first download, and
`reconcileReadingProgress` during sync for documents already on the device. Both
only record; the jump happens in `onReaderReady`, which fires a `GotoPercent`
event and clears the seed so it applies exactly once. `GotoPercent` is used
rather than writing the sidecar's `last_percent` because `readerrolling` honours
`last_percent` only when `last_xpointer` is absent, and marks that branch
deprecated. `percent_finished` is still written at seed time so the File Manager
shows Reader's figure before the document is opened. Because `saveSettings`
flushes the entire settings table, the reconciliation pass mutates its maps in
memory and writes once at the end.

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

## Phase 1C: Feed search, virtual views, and read-only highlights

`api/reader.lua` now shares one `scanMetadata(cursor, predicate)` helper
between Library search and a new `viewMetadata(view_key, cursor)`. Search's
location set gained `feed`; views (`quick_reads`, `long_reads`, `in_progress`)
deliberately keep their own narrower location set (Inbox/Later/Shortlist/
Archive) and exclude Feed, since a view is meant to help pick what to
download next rather than browse a subscription stream. Both still page
one 25-document metadata-only request at a time and never preload the full
library. `ui/browser.lua` exposes views the same way it exposes Search
results: a `Load more` row, tap-to-select, hold-for-details, and the existing
selected-download flow -- picking a view never downloads anything by itself.

Highlights got a second, read-only adapter and UI, kept separate from the
existing export pipeline:

- `api/highlights_read.lua` wraps v2 `GET /highlights/` (paginated, local
  text/note search since there is no documented full-text query parameter),
  `GET /books/<id>/` (fetched lazily, one book at a time, only when a
  highlight's details are opened -- never a bulk join across a page of
  highlights), and `GET /review/` (the documented Daily Review endpoint,
  which already nests each highlight's title/author so no book lookup is
  needed there).
- `ui/highlights.lua` is a new text-first browser mirroring `ui/browser.lua`'s
  patterns (InputDialog search, paginated "Search next page", tap for details)
  but with no selection or download concept, since highlights are read, not
  downloaded.
- `main.lua`'s `callAPI` gained an optional fifth `base_url` parameter so the
  read-only highlights adapter can reuse its existing retry/rate-limit/error
  handling against `HIGHLIGHTS_API_ENDPOINT` instead of duplicating it.

None of this touches `api/highlights.lua`'s export pipeline, `exportHighlights`,
or highlight CREATE payloads.

## Related

- [Phase 1 implementation plan](PHASE-1.md)
- [Roadmap](ROADMAP.md)
