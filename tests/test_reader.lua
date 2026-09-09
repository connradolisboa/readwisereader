package.path = (os.getenv("PLUGIN_PATH") or "readwisereader.koplugin") .. "/?.lua;" .. package.path
local Reader = require("api/reader")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %-46s got=%s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-46s %s", name, tostring(got)))
    end
end

print("== Reader document normalization ==")
local document = Reader.normalizeDocument({
    id = "reader-book-id",
    title = "Local Book",
    notes = "My Reader note",
    reading_progress = 0.42,
})
check("normalizes a document", document ~= nil, true)
check("keeps the top-level note", document.notes, "My Reader note")
check("keeps Reader progress", document.reading_progress, 0.42)
check("empty note stays absent", Reader.normalizeDocument({ id = "empty", notes = "" }).notes, nil)

local endpoints = {}
local api = Reader:new{
    request = function(_method, endpoint)
        table.insert(endpoints, endpoint)
        return { results = { { id = "reader-book-id", title = "Local Book" } } }
    end,
}
api:getDocument("reader-book-id", false)
api:getDocument("reader-book-id")
check("metadata fetch does not request HTML", endpoints[1]:find("withHtmlContent=false", 1, true) ~= nil, true)
check("download fetch still requests HTML", endpoints[2]:find("withHtmlContent=true", 1, true) ~= nil, true)

print(failures == 0 and "\nALL PASS" or string.format("\n%d FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
