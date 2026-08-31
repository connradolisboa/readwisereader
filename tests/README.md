# Tests

Pure-Lua unit tests for the parts of the plugin that do not need a running
KOReader: payload construction, batching, and error handling. They stub the HTTP
transport, so they never touch a real Readwise account.

Run them from the repository root with the same runtime KOReader ships:

    luajit tests/test_highlights.lua

Anything that requires KOReader's own modules (`clip`, `docsettings`,
`readhistory`, ...) or a live API token is out of scope here and still has to be
verified on device.
