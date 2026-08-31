-- Reader list adapter for metadata-only UI flows. Transport/authentication stay
-- with main.lua's established callAPI implementation.
local Reader = {}
Reader.__index = Reader

local PAGE_SIZE = 25

local function stringOrNil(value)
    return type(value) == "string" and value ~= "" and value or nil
end

local function normalizeTags(tags)
    if type(tags) ~= "table" then
        return nil
    end
    local normalized = {}
    for _, tag in ipairs(tags) do
        if type(tag) == "string" and tag ~= "" then
            table.insert(normalized, tag)
        end
    end
    return #normalized > 0 and normalized or nil
end

function Reader:new(options)
    assert(type(options) == "table" and type(options.request) == "function", "Reader request adapter required")
    return setmetatable({ request = options.request }, self)
end

function Reader.normalizeDocument(document)
    if type(document) ~= "table" or not stringOrNil(document.id) then
        return nil
    end
    return {
        id = document.id,
        title = stringOrNil(document.title) or "Untitled",
        author = stringOrNil(document.author),
        site_name = stringOrNil(document.site_name),
        category = stringOrNil(document.category),
        location = stringOrNil(document.location),
        reading_time = stringOrNil(document.reading_time),
        reading_progress = type(document.reading_progress) == "number" and document.reading_progress or nil,
        image_url = stringOrNil(document.image_url),
        source_url = stringOrNil(document.source_url),
        summary = stringOrNil(document.summary),
        updated_at = stringOrNil(document.updated_at),
        tags = normalizeTags(document.tags),
    }
end

function Reader:listMetadata(location, cursor)
    local endpoint = "/list/?location=" .. location .. "&withHtmlContent=false&withTags=true&limit=" .. PAGE_SIZE
    if type(cursor) == "string" and cursor ~= "" then
        endpoint = endpoint .. "&pageCursor=" .. cursor
    end

    local response, err = self.request("GET", endpoint)
    if not response then
        return nil, err or "request_failed"
    end

    local documents = {}
    if type(response.results) == "table" then
        for _, document in ipairs(response.results) do
            local normalized = Reader.normalizeDocument(document)
            if normalized then
                table.insert(documents, normalized)
            end
        end
    end
    local next_cursor = stringOrNil(response.nextPageCursor)
    return { documents = documents, next_cursor = next_cursor }
end

return Reader
