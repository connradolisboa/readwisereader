# Roadmap

This is an incremental product plan. Existing automatic sync, completion archive,
and Kindle-to-Readwise highlight export remain in place throughout.

## Phase 1: native covers and selected downloads

- Add a metadata-only Reader list path for Inbox (`new`), Later, and Shortlist.
- Add a Kindle-friendly KOReader picker that selects documents before download.
- Fetch full HTML only for selected documents.
- Fetch `image_url` best-effort and install it with `DocSettings:flushCustomCover`
  so bundled CoverBrowser modes can use it.
- Preserve existing automatic sync and settings/filename conventions.

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

- Determine whether KOReader reading state can map usefully to generated HTML.
- Investigate a Daily Digest EPUB only after a supported data source and
  Kindle-native EPUB workflow are confirmed.
- Improve content/image conversion and offline recovery.
- Explore Reader-to-Kindle highlights only with a stable source-location model.

## Known API limitations

- Public Reader list data includes `reading_progress`, but UPDATE has no
  documented percentage or position field.
- Documented writable locations are `new`, `later`, `archive`, and `feed`;
  Shortlist is listable but not documented as writable.
- No public Reader HTTP endpoint was found for Daily Digest or document search.
- `seen` is boolean and not a progress substitute.
- Exported highlights have no reliable reciprocal location map into generated HTML.

## Experimental future features

- Multi-article Daily Digest EPUB.
- Search via a future official API or an explicitly approved experiment.
- Reader-to-Kindle highlight import.
- Generated fallback covers for documents without `image_url`.
- Clearly-labelled approximate progress mapping, only if testing justifies it.

## Related

- [Architecture](ARCHITECTURE.md)
- [Phase 1 implementation plan](PHASE-1.md)
