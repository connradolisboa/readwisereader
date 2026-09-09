# Tests

Pure-Lua unit tests for the parts of the plugin that do not need a running
KOReader: highlight payload construction/batching/error handling and explicit
local-file-to-Reader link persistence. They stub the HTTP transport, so they
never touch a real Readwise account.

Run them from the repository root with the same runtime KOReader ships:

    luajit tests/test_highlights.lua
    luajit tests/test_local_links.lua
    luajit tests/test_progress_note.lua
    luajit tests/test_reader.lua

Anything that requires KOReader's own modules (`clip`, `docsettings`,
`readhistory`, ...) or a live API token is out of scope here and still has to be
verified on device.
