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

print("\n== Library search includes Feed ==")
local search_page = {
    { id = "1", title = "Feed item", location = "feed" },
    { id = "2", title = "Later item", location = "later" },
    { id = "3", title = "Child note", location = "later", parent_id = "2" },
}
local search_api = Reader:new{
    request = function() return { results = search_page } end,
}
local search_result = search_api:searchMetadata("item")
check("Feed and Later both match", #search_result.documents, 2)
local search_ids = {}
for _, document in ipairs(search_result.documents) do search_ids[document.id] = true end
check("Feed item is included", search_ids["1"], true)
check("child document is excluded", search_ids["3"], nil)

print("\n== Views ==")
local view_page = {
    { id = "quick", title = "Quick", location = "later", reading_time = 3 },
    { id = "long", title = "Long", location = "later", reading_time = 45 },
    { id = "mid", title = "Mid", location = "later", reading_time = 12 },
    { id = "started", title = "Started", location = "shortlist", reading_progress = 0.5 },
    { id = "finished", title = "Finished", location = "shortlist", reading_progress = 1 },
    { id = "unstarted", title = "Unstarted", location = "shortlist", reading_progress = 0 },
    { id = "feed-quick", title = "Feed quick", location = "feed", reading_time = 2 },
    { id = "child-quick", title = "Child quick", location = "later", reading_time = 2, parent_id = "quick" },
}
local view_api = Reader:new{
    request = function() return { results = view_page } end,
}

local function idsOf(documents)
    local ids = {}
    for _, document in ipairs(documents) do table.insert(ids, document.id) end
    table.sort(ids)
    return table.concat(ids, ",")
end

check("quick_reads matches short reading_time", idsOf(view_api:viewMetadata("quick_reads").documents), "quick")
check("long_reads matches long reading_time", idsOf(view_api:viewMetadata("long_reads").documents), "long")
check("in_progress matches partial progress only", idsOf(view_api:viewMetadata("in_progress").documents), "started")
check("unknown view is rejected", view_api:viewMetadata("nonsense"), nil)

print(failures == 0 and "\nALL PASS" or string.format("\n%d FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
