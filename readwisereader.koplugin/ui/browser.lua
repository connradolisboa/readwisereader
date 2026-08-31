-- Text-first Reader browser. It deliberately fetches only list metadata; later
-- phases can add selection/download actions to these same menu rows.
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local Browser = {}
Browser.__index = Browser

local LOCATIONS = {
    { value = "new", text = "Inbox" },
    { value = "later", text = "Later" },
    { value = "shortlist", text = "Shortlist" },
}

local function displayProgress(progress)
    if type(progress) ~= "number" then
        return nil
    end
    local percent = math.floor(math.max(0, math.min(1, progress)) * 100 + 0.5)
    return tostring(percent) .. "%"
end

local function joinParts(parts)
    local present = {}
    for _, value in ipairs(parts) do
        if type(value) == "string" and value ~= "" then
            table.insert(present, value)
        end
    end
    return table.concat(present, " · ")
end

function Browser:new(options)
    assert(type(options) == "table" and options.reader_api, "Reader API required")
    return setmetatable({
        reader_api = options.reader_api,
        is_configured = options.is_configured,
        downloaded_ids = options.downloaded_ids,
        show_progress = options.show_progress,
        hide_progress = options.hide_progress,
        pages = {},
        downloaded_lookup = nil,
    }, self)
end

function Browser:showError(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 5 })
end

function Browser:getDownloadedLookup()
    if not self.downloaded_lookup then
        self.downloaded_lookup = self.downloaded_ids() or {}
    end
    return self.downloaded_lookup
end

function Browser:load(location, append)
    if self.is_configured and not self.is_configured() then
        self:showError("Configure your Readwise access token before browsing Reader.")
        return nil
    end
    local current = self.pages[location]
    local cursor = append and current and current.next_cursor or nil
    if append and not cursor then
        return current
    end

    self.show_progress("Loading Reader documents…")
    local page, err = self.reader_api:listMetadata(location, cursor)
    self.hide_progress()
    if not page then
        self:showError(err == "network_error"
            and "Reader browsing requires a network connection."
            or "Could not load Reader documents. Please check your token and connection.")
        return nil
    end

    if append and current then
        for _, document in ipairs(page.documents) do
            table.insert(current.documents, document)
        end
        current.next_cursor = page.next_cursor
    else
        self.pages[location] = page
    end
    return self.pages[location]
end

function Browser:rowText(document)
    local prefix = self:getDownloadedLookup()[document.id] and "✓ " or ""
    local attribution = document.author or document.site_name
    local subtitle = joinParts({
        attribution,
        document.reading_time,
        displayProgress(document.reading_progress),
    })
    return subtitle ~= "" and prefix .. document.title .. "\n" .. subtitle
        or prefix .. document.title
end

function Browser:showDocumentInfo(document)
    local downloaded = self:getDownloadedLookup()[document.id] and "Yes" or "No"
    local lines = { document.title }
    local fields = {
        { "Author", document.author },
        { "Site", document.site_name },
        { "Category", document.category },
        { "Location", document.location },
        { "Reading time", document.reading_time },
        { "Progress", displayProgress(document.reading_progress) },
        { "Tags", document.tags and table.concat(document.tags, ", ") or nil },
        { "Summary", document.summary },
        { "Downloaded", downloaded },
    }
    for _, field in ipairs(fields) do
        if field[2] then
            table.insert(lines, field[1] .. ": " .. field[2])
        end
    end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n\n") })
end

function Browser:getDocumentItems(location)
    local page = self.pages[location] or self:load(location, false)
    if not page then
        return {
            { text = "Retry", callback = function(menu)
                self:load(location, false)
                if menu then menu:updateItems() end
            end },
        }
    end
    if #page.documents == 0 then
        return { { text = "No documents in this location.", enabled = false } }
    end

    local items = {}
    for _, document in ipairs(page.documents) do
        local row_document = document
        table.insert(items, {
            text = self:rowText(row_document),
            callback = function() self:showDocumentInfo(row_document) end,
        })
    end
    if page.next_cursor then
        table.insert(items, {
            text = "Load more",
            keep_menu_open = true,
            callback = function(menu)
                self:load(location, true)
                if menu then menu:updateItems() end
            end,
        })
    end
    return items
end

function Browser:getLocationItems()
    -- A browser opening is an online session, not a persistent cache. Keep
    -- cursor pages only while the user navigates inside this menu hierarchy.
    self.pages = {}
    self.downloaded_lookup = nil
    local items = {}
    for _, location in ipairs(LOCATIONS) do
        local location_value = location.value
        table.insert(items, {
            text = location.text,
            sub_item_table_func = function()
                return self:getDocumentItems(location_value)
            end,
        })
    end
    return items
end

return Browser
