package.path = (os.getenv("PLUGIN_PATH") or "readwisereader.koplugin") .. "/?.lua;" .. package.path
local H = require("api/highlights")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %-46s got=%s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-46s %s", name, tostring(got)))
    end
end

-- A fake transport that records every request and replies the way the
-- documented v2 endpoint does: one book object per request carrying the ids of
-- the highlights it created or updated.
local function fakeApi(opts)
    opts = opts or {}
    local log = { requests = {}, counts = {} }
    local api = H:new{
        request = function(endpoint, method, body)
            table.insert(log.requests, { endpoint = endpoint, method = method, body = body })
            table.insert(log.counts, #body.highlights)
            if opts.reject then
                for _, h in ipairs(body.highlights) do
                    if opts.reject(h) then
                        return nil, "Request failed: 400 Bad Request"
                    end
                end
            end
            local ids = {}
            for i = 1, #body.highlights do ids[i] = i end
            return { { id = 1, title = "Book", modified_highlights = ids } }
        end,
    }
    return api, log
end

local function book(n, overrides)
    local chapter = {}
    for i = 1, n do
        local c = { text = "highlight " .. i, time = 1700000000 + i, pn_xp = "/body/DocFragment[" .. i .. "]" }
        for k, v in pairs(overrides and overrides[i] or {}) do c[k] = v end
        table.insert(chapter, c)
    end
    return {
        booknotes = { chapter },
        context = {
            title = "On Agency", author = "Henrik Karlsson",
            source_url = "https://www.henrikkarlsson.xyz/p/agency",
            category = "articles",
            highlight_url_base = "https://read.readwise.io/read/01m0f0sf3faxh0qftse4r32m06",
        },
    }
end

print("== batching ==")
local api, log = fakeApi()
local report = api:export({ book(250) })
check("requests for 250 highlights", #log.requests, 3)
check("first batch size", log.counts[1], 100)
check("last batch size", log.counts[3], 50)
check("sent", report.sent, 250)
check("confirmed from modified_highlights", report.confirmed, 250)
check("endpoint", log.requests[1].endpoint, "/highlights")
check("method", log.requests[1].method, "POST")

print("\n== payload shape ==")
local h = log.requests[1].body.highlights[1]
check("text", h.text, "highlight 1")
check("title matches Reader doc", h.title, "On Agency")
check("author matches Reader doc", h.author, "Henrik Karlsson")
check("source_url matches Reader doc", h.source_url, "https://www.henrikkarlsson.xyz/p/agency")
check("source_type", h.source_type, "koreader")
check("location_type", h.location_type, "order")
check("location is 1-based order", h.location, 1)
check("highlighted_at is ISO 8601 UTC", h.highlighted_at, "2023-11-14T22:13:21Z")
check("note absent when unset", h.note, nil)

print("\n== page location ==")
local api_page, log_page = fakeApi()
api_page:export({ book(2, { [1] = { page = 42 }, [2] = { page = "N/A" } }) })
local page_highlights = log_page.requests[1].body.highlights
check("numeric page wins over order", page_highlights[1].location_type, "page")
check("numeric page value", page_highlights[1].location, 42)
check("non-numeric page falls back to order", page_highlights[2].location_type, "order")
check("order fallback is 1-based", page_highlights[2].location, 2)

print("\n== notes are carried ==")
local api2, log2 = fakeApi()
api2:export({ book(1, { [1] = { note = "my annotation" } }) })
check("note reaches the payload", log2.requests[1].body.highlights[1].note, "my annotation")

print("\n== highlight_url survives edits ==")
local base = "https://read.readwise.io/read/abc"
local original = { text = "before", time = 1700000001, pn_xp = "/body/p[3]" }
local edited   = { text = "AFTER",  time = 1700000001, pn_xp = "/body/p[3]" }
local other    = { text = "before", time = 1700000002, pn_xp = "/body/p[3]" }
check("stable across a text edit",
    H.buildHighlightUrl(base, original) == H.buildHighlightUrl(base, edited), true)
check("differs for a different annotation",
    H.buildHighlightUrl(base, original) ~= H.buildHighlightUrl(base, other), true)
check("shape", H.buildHighlightUrl(base, original), base .. "#koreader-1700000001-102dd6d4")
-- The hash must not depend on the Lua build, or the same annotation would get a
-- different URL on a different device and re-import as a duplicate.
check("hash is deterministic",
    H.buildHighlightUrl(base, original), H.buildHighlightUrl(base, { time = 1700000001, pn_xp = "/body/p[3]" }))
check("hash survives a long pointer without overflowing",
    #H.buildHighlightUrl(base, { time = 1, pn_xp = string.rep("/body/DocFragment[9]/p[123]", 200) }),
    #base + #"#koreader-1-" + 8)
check("nil without a base url", H.buildHighlightUrl(nil, original), nil)
check("nil without time or pointer", H.buildHighlightUrl(base, { text = "x" }), nil)

print("\n== local validation ==")
local api3, log3 = fakeApi()
local r3 = api3:export({ book(3, {
    [2] = { text = "" },
    [3] = { text = string.rep("x", 9000) },
}) })
check("only the valid highlight is sent", r3.sent, 1)
check("two skipped locally", #r3.skipped, 2)
check("empty text named", r3.skipped[1].message, "highlight 2: empty text")
check("book named on skip", r3.skipped[1].book, "On Agency")
check("oversize text explained",
    r3.skipped[2].message, "highlight 3: text is 9000 characters, over the 8191 limit")
check("no request wasted on invalid input", log3.counts[1], 1)

print("\n== one bad highlight does not sink the batch ==")
local api4, log4 = fakeApi{ reject = function(h) return h.text == "highlight 7" end }
local r4 = api4:export({ book(10) })
check("batch retried per item", #log4.requests, 11)
check("nine confirmed", r4.confirmed, 9)
check("one failure reported", #r4.failures, 1)
check("failure names its book", r4.failures[1].book, "On Agency")

print("\n== problem summary ==")
local summary, total = H.summarizeProblems(r3, 3)
check("counts every problem", total, 2)
check("summary mentions the book", summary:find("On Agency", 1, true) ~= nil, true)
check("nil when clean", (H.summarizeProblems({ failures = {}, skipped = {} })), nil)

print("\n== category mapping ==")
check("epub", H.mapCategory("epub"), "books")
check("pdf", H.mapCategory("pdf"), "books")
check("tweet", H.mapCategory("tweet"), "tweets")
check("podcast", H.mapCategory("podcast"), "podcasts")
check("article", H.mapCategory("article"), "articles")
check("nil falls back", H.mapCategory(nil), "articles")
check("unknown falls back", H.mapCategory("something-new"), "articles")

print("\n== empty input ==")
local api5, log5 = fakeApi()
local r5 = api5:export({})
check("no requests", #log5.requests, 0)
check("confirmed zero", r5.confirmed, 0)

print(failures == 0 and "\nALL PASS" or string.format("\n%d FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
