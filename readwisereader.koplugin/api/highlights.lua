-- Readwise v2 highlights adapter. Transport and authentication stay with
-- main.lua's makeJsonRequest, mirroring how api/reader.lua defers to callAPI.
--
-- Two documented v2 behaviours drive this design:
--
--   * "we de-dupe highlights by title/author/text/source_url" -- so re-sending
--     an unchanged highlight is harmless, but an *edited* one arrives as a
--     second highlight unless it carries a stable highlight_url.
--   * "you can obtain ids of the highlights that were created/updated" under
--     each returned book's modified_highlights key -- so the server, not our
--     loop counter, is the authority on how many highlights actually landed.
local Highlights = {}
Highlights.__index = Highlights

-- The CREATE endpoint takes an array of highlights that may span several
-- books. Batching cuts a full-library export from one request per highlight to
-- one per hundred, which is what keeps large libraries under the rate limit.
local BATCH_SIZE = 100

-- Documented v2 field limits. Exceeding either is a 400 for the whole batch,
-- so they are enforced locally where the offending highlight can be named.
local MAX_TEXT = 8191
local MAX_NOTE = 8191

-- Reader's category vocabulary is wider than the four v2 dashboard categories,
-- so map it rather than calling everything an article.
local CATEGORY_MAP = {
    epub = "books",
    pdf = "books",
    book = "books",
    tweet = "tweets",
    podcast = "podcasts",
    audiobook = "podcasts",
    article = "articles",
    email = "articles",
    rss = "articles",
    video = "articles",
}

local function stringOrNil(value)
    return type(value) == "string" and value ~= "" and value or nil
end

-- djb2, kept inside Lua 5.1's exact-integer range. Used only to compress a
-- position pointer into a URL fragment, so collision resistance matters more
-- than cryptographic strength.
local function shortHash(value)
    local hash = 5381
    for index = 1, #value do
        hash = (hash * 33 + value:byte(index)) % 0x7FFFFFFF
    end
    return string.format("%08x", hash)
end

function Highlights:new(options)
    assert(type(options) == "table" and type(options.request) == "function",
        "Highlights request adapter required")
    return setmetatable({ request = options.request }, self)
end

function Highlights.mapCategory(reader_category)
    return CATEGORY_MAP[stringOrNil(reader_category) or ""] or "articles"
end

-- A highlight's identity has to survive the user editing its text or its note,
-- otherwise the edit lands in Readwise as a duplicate rather than a revision.
-- KOReader's annotation datetime is assigned at creation and is not touched by
-- later edits, so it anchors the URL; the position pointer disambiguates the
-- case of two highlights made inside the same second.
function Highlights.buildHighlightUrl(base_url, clipping)
    base_url = stringOrNil(base_url)
    if not base_url then
        return nil
    end
    local parts = {}
    if type(clipping.time) == "number" and clipping.time > 0 then
        table.insert(parts, tostring(clipping.time))
    end
    local pointer = clipping.pn_xp
    if pointer ~= nil then
        table.insert(parts, shortHash(tostring(pointer)))
    end
    if #parts == 0 then
        return nil
    end
    return base_url .. "#koreader-" .. table.concat(parts, "-")
end

-- `context` carries the fields that decide which Readwise book the highlight
-- joins. Matching the Reader document's title, author and source_url exactly is
-- what gives the export its best chance of grouping under the existing article
-- instead of opening a parallel one.
function Highlights.buildHighlight(clipping, context, order)
    local text = stringOrNil(clipping.text)
    if not text then
        return nil, "empty text"
    end
    if #text > MAX_TEXT then
        return nil, string.format("text is %d characters, over the %d limit", #text, MAX_TEXT)
    end

    local note = stringOrNil(clipping.note)
    if note and #note > MAX_NOTE then
        return nil, string.format("note is %d characters, over the %d limit", #note, MAX_NOTE)
    end

    local highlight = {
        text = text,
        title = context.title,
        author = context.author,
        source_url = context.source_url,
        image_url = context.image_url,
        source_type = "koreader",
        category = context.category,
        note = note,
        -- KOReader's page/XPointer values are not uniformly meaningful for the
        -- generated HTML, but the parser's iteration order is. `order` is the
        -- documented location_type for exactly that situation.
        location = order,
        location_type = "order",
        highlight_url = Highlights.buildHighlightUrl(context.highlight_url_base, clipping),
    }
    if type(clipping.time) == "number" and clipping.time > 0 then
        highlight.highlighted_at = os.date("!%Y-%m-%dT%TZ", clipping.time)
    end
    return highlight
end

-- Flattens one book's nested chapter/clipping structure into payloads, and
-- reports the highlights it had to drop rather than letting them vanish into a
-- book-level success.
function Highlights.buildBook(booknotes, context)
    local payloads, skipped, order = {}, {}, 0
    for _, chapter in ipairs(booknotes) do
        for _, clipping in ipairs(chapter) do
            order = order + 1
            local highlight, err = Highlights.buildHighlight(clipping, context, order)
            if highlight then
                table.insert(payloads, highlight)
            else
                table.insert(skipped, string.format("highlight %d: %s", order, err))
            end
        end
    end
    return payloads, skipped
end

function Highlights.countModified(response)
    if type(response) ~= "table" then
        return 0
    end
    local count = 0
    for _, book in ipairs(response) do
        if type(book) == "table" and type(book.modified_highlights) == "table" then
            count = count + #book.modified_highlights
        end
    end
    return count
end

function Highlights:postBatch(payloads)
    return self.request("/highlights", "POST", { highlights = payloads })
end

-- Posts one batch, and on failure retries its members individually so that a
-- single rejected highlight cannot sink the ninety-nine valid ones beside it.
-- The retry only runs on the error path, so the happy path stays at one
-- request per batch.
function Highlights:sendBatch(entries)
    local payloads = {}
    for _, entry in ipairs(entries) do
        table.insert(payloads, entry.payload)
    end

    local response, err = self:postBatch(payloads)
    if response then
        return Highlights.countModified(response), {}
    end

    if #entries == 1 then
        return 0, { { book = entries[1].book, message = tostring(err) } }
    end

    local confirmed, failures = 0, {}
    for _, entry in ipairs(entries) do
        local single, single_err = self:postBatch({ entry.payload })
        if single then
            confirmed = confirmed + Highlights.countModified(single)
        else
            table.insert(failures, { book = entry.book, message = tostring(single_err) })
        end
    end
    return confirmed, failures
end

-- `books` is an array of { context = <context>, booknotes = <parsed book> }.
--
-- Returns a report describing what the *server* confirmed, not what the loop
-- attempted:
--   sent      -- highlights we considered valid and put on the wire
--   confirmed -- highlights Readwise reported as created or updated
--   skipped   -- highlights rejected locally, with the reason
--   failures  -- highlights the server rejected, with the reason
function Highlights:export(books)
    local report = { sent = 0, confirmed = 0, skipped = {}, failures = {} }
    local queue = {}

    local function flush()
        if #queue == 0 then
            return
        end
        local confirmed, failures = self:sendBatch(queue)
        report.confirmed = report.confirmed + confirmed
        for _, failure in ipairs(failures) do
            table.insert(report.failures, failure)
        end
        queue = {}
    end

    for _, book in ipairs(books) do
        local title = book.context.title or "Untitled"
        local payloads, skipped = Highlights.buildBook(book.booknotes, book.context)
        for _, message in ipairs(skipped) do
            table.insert(report.skipped, { book = title, message = message })
        end
        for _, payload in ipairs(payloads) do
            report.sent = report.sent + 1
            table.insert(queue, { payload = payload, book = title })
            if #queue >= BATCH_SIZE then
                flush()
            end
        end
    end
    flush()

    return report
end

-- Collapses a report's problems into at most `limit` lines for an InfoMessage,
-- naming the book each one came from.
function Highlights.summarizeProblems(report, limit)
    limit = limit or 3
    local lines, total = {}, 0
    for _, group in ipairs({ report.failures, report.skipped }) do
        for _, problem in ipairs(group) do
            total = total + 1
            if #lines < limit then
                table.insert(lines, problem.book .. ": " .. problem.message)
            end
        end
    end
    if total == 0 then
        return nil, 0
    end
    if total > #lines then
        table.insert(lines, string.format("...and %d more", total - #lines))
    end
    return table.concat(lines, "\n"), total
end

return Highlights
