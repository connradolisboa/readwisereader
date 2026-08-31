# Architecture

## Current implementation

The repository contains one runtime module: `readwisereader.koplugin/main.lua`
(2,555 lines) plus `_meta.lua`. There are no vendored dependencies, tests,
fixtures, or KOReader source files in this checkout.

`ReadwiseReader` is a `WidgetContainer`. `init()` opens
`settings/readwisereader.lua`, initializes state, and registers the menu.
`onDispatcherRegisterActions()` exposes `SynchronizeReadwiseReader`; that event
uses `NetworkMgr:runWhenOnline()` before `synchronize()` runs.

### What `main.lua` currently does

| Area | Main implementation |
| --- | --- |
| Settings | `LuaSettings` stores the access token, directory, filters, sync options, last-sync timestamp, document tag/location maps, author/source URL lookup maps, and the cover URL cache index. |
| Authentication/API | `callAPI()` sends `Authorization: Token <token>` to Reader v3, retries Kindle `wantread`, and handles 429 `Retry-After`. `makeJsonRequest()` posts v2 highlight payloads. |
| Document retrieval | `getDocumentList()` pages `new`, `later`, and `shortlist`, requesting `withHtmlContent=true`; it filters and applies the sync limit while gathering. `getArchivedDocuments()` pages archive changes. |
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
archive cleanup, and menu UI in one file. More importantly, metadata listing and
full HTML download are coupled, blocking a light picker.

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
| Search | Requires experimentation/private API | No public search HTTP endpoint in the Reader API reference. |

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
  ui/picker.lua                # browser and selected download flow
  ui/settings.lua              # later settings extraction
  util/http.lua                # shared timeout/retry/binary GET policy
```

Phase 1A created `library/covers.lua`. It streams HTTPS covers to
`<download directory>/.readwise/covers/<document-id>.<jpg|png>`, validates JPEG
or PNG signatures, and applies the cached file through `DocSettings`. The
persisted `document_cover_urls` map avoids re-downloading a known usable cover
when an article is re-downloaded; `download_covers` defaults to true.
`api/reader.lua` and `ui/picker.lua` remain future work. Retain the filename
format, `processHtmlContent`, clipping/export, collection calls, archive cleanup,
and existing settings behavior until covered by tests and device verification.

## Related

- [Phase 1 implementation plan](PHASE-1.md)
- [Roadmap](ROADMAP.md)
