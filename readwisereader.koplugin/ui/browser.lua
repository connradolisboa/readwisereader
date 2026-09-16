-- Reusable, text-first Reader document browser. Metadata pages stay in memory
-- only for the current menu session. Tap toggles selection; hold shows details.
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")

local Browser = {}
Browser.__index = Browser

local LOCATIONS = {
    { value = "new", text = "Inbox" },
    { value = "later", text = "Later" },
    { value = "shortlist", text = "Shortlist" },
}

local LOCATION_LABELS = {
    new = "Inbox",
    later = "Later",
    shortlist = "Shortlist",
    archive = "Archive",
    feed = "Feed",
}

-- Virtual views over the same metadata search already loads: no download
-- happens by picking one, they just narrow what's shown so items can be
-- selected for download, same as a location tab or search results.
local VIEWS = {
    { key = "quick_reads", text = "Quick Reads" },
    { key = "long_reads", text = "Long Reads" },
    { key = "in_progress", text = "In Progress" },
}

local function displayProgress(progress)
    if type(progress) ~= "number" then
        return nil
    end
    local percent = math.floor(math.max(0, math.min(1, progress)) * 100 + 0.5)
    return tostring(percent) .. "%"
end

local function joinParts(...)
    local present = {}
    for index = 1, select("#", ...) do
        local value = select(index, ...)
        if type(value) == "string" and value ~= "" then
            table.insert(present, value)
        end
    end
    return table.concat(present, " · ")
end

local function trim(value)
    return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
end

local function replaceMenuItems(menu, items)
    if not menu or type(menu.item_table) ~= "table" then
        return
    end
    while #menu.item_table > 0 do
        table.remove(menu.item_table)
    end
    for _, item in ipairs(items) do
        table.insert(menu.item_table, item)
    end
    menu:updateItems()
end

function Browser:new(options)
    assert(type(options) == "table" and options.reader_api, "Reader API required")
    assert(type(options.download_documents) == "function", "Document downloader required")
    return setmetatable({
        reader_api = options.reader_api,
        is_configured = options.is_configured,
        downloaded_ids = options.downloaded_ids,
        download_documents = options.download_documents,
        show_progress = options.show_progress,
        hide_progress = options.hide_progress,
        pages = {},
        views = {},
        downloaded_lookup = nil,
        selected = {},
        search = nil,
        link_local_book = options.link_local_book,
        link_search = nil,
    }, self)
end

function Browser:showError(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 5 })
end

function Browser:errorText(err, status, action)
    if err == "network_error" then
        return "Reader " .. action .. " requires a network connection."
    end
    if status == 401 or status == 403 then
        return "Reader authentication failed. Check your Readwise access token."
    end
    return "Could not " .. action .. " Reader documents. Please check your token and connection."
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
    local page, err, status = self.reader_api:listMetadata(location, cursor)
    self.hide_progress()
    if not page then
        self:showError(self:errorText(err, status, "load"))
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

function Browser:loadSearch(append)
    local current = self.search
    if not current then
        return nil
    end
    local cursor = append and current.next_cursor or nil
    if append and not cursor then
        return current
    end

    self.show_progress(append and "Searching the next 25 Reader documents…"
        or "Searching Reader metadata…")
    local page, err, status = self.reader_api:searchMetadata(current.query, cursor)
    self.hide_progress()
    if not page then
        current.load_failed = true
        self:showError(self:errorText(err, status, "search"))
        return nil
    end
    current.load_failed = nil

    if append then
        for _, document in ipairs(page.documents) do
            table.insert(current.documents, document)
        end
        current.next_cursor = page.next_cursor
        current.scanned = current.scanned + page.scanned
    else
        current.documents = page.documents
        current.next_cursor = page.next_cursor
        current.scanned = page.scanned
    end
    return current
end

function Browser:rowText(document, show_location)
    local plain = show_location == "plain"
    local selected = plain and "" or (self.selected[document.id] and "[x] " or "[ ] ")
    local downloaded = plain and "" or (self:getDownloadedLookup()[document.id] and "✓ " or "")
    local attribution = document.author or document.site_name
    local subtitle = joinParts(
        attribution,
        document.reading_time,
        displayProgress(document.reading_progress),
        show_location and LOCATION_LABELS[document.location] or nil)
    local title = selected .. downloaded .. document.title
    return subtitle ~= "" and title .. "\n" .. subtitle or title
end

function Browser:showLinkDocumentInfo(document)
    UIManager:show(InfoMessage:new{ text = self:formatDetails(document) })
end

function Browser:confirmLink(local_book, document, menu)
    local attribution = document.author and ("\nAuthor: " .. document.author) or ""
    UIManager:show(ConfirmBox:new{
        text = "Link this local book to the selected Reader document?\n\n"
            .. "Local: " .. local_book.title .. "\n"
            .. "Reader: " .. document.title .. attribution
            .. "\n\nThis does not download HTML. Future exports use this Reader document's "
            .. "metadata, but Readwise does not provide a guaranteed Reader-anchored highlight API.",
        ok_text = "Link",
        ok_callback = function()
            local link = self.link_local_book and self.link_local_book(local_book.filepath, document)
            if not link then
                self:showError("Could not save the local book link.")
                return
            end
            UIManager:show(InfoMessage:new{
                text = "Linked local book to:\n" .. document.title
                    .. "\n\nUse Advanced sync → Export highlights to Readwise."
            })
            if menu then menu:updateItems() end
        end,
    })
end

function Browser:getLinkSearchItems()
    local search = self.link_search
    if not search then
        return {}
    end
    local local_book = search.local_book
    local items = {
        {
            text = "Linking local book: " .. local_book.title,
            enabled = false,
        },
        {
            text = "New search…",
            keep_menu_open = true,
            separator = true,
            callback = function(menu) self:showLinkSearchDialog(local_book, menu) end,
        },
    }

    for _, document in ipairs(search.documents) do
        local row_document = document
        table.insert(items, {
            text_func = function() return self:rowText(row_document, "plain") end,
            keep_menu_open = true,
            callback = function(menu)
                self:confirmLink(local_book, row_document, menu)
            end,
            hold_callback = function()
                self:showLinkDocumentInfo(row_document)
            end,
        })
    end

    if #search.documents == 0 then
        local status = search.load_failed
            and "Search failed. No results were changed."
            or search.next_cursor
            and string.format("No matches in %d scanned documents yet.", search.scanned)
            or string.format("No matches in %d scanned documents.", search.scanned)
        table.insert(items, { text = status, enabled = false })
    end
    if search.load_failed then
        table.insert(items, {
            text = "Retry search page",
            keep_menu_open = true,
            callback = function(menu)
                self:loadLinkSearch(search.scanned > 0)
                if menu then replaceMenuItems(menu, self:getLinkSearchItems()) end
            end,
        })
    end
    if search.next_cursor and not search.load_failed then
        table.insert(items, {
            text = string.format("Search next page (%d scanned)", search.scanned),
            keep_menu_open = true,
            callback = function(menu)
                self:loadLinkSearch(true)
                if menu then replaceMenuItems(menu, self:getLinkSearchItems()) end
            end,
        })
    end
    return items
end

function Browser:loadLinkSearch(append)
    local current = self.link_search
    if not current then
        return nil
    end
    local cursor = append and current.next_cursor or nil
    if append and not cursor then
        return current
    end

    self.show_progress(append and "Searching the next 25 Reader documents…"
        or "Searching Reader metadata…")
    local page, err, status = self.reader_api:searchMetadata(current.query, cursor)
    self.hide_progress()
    if not page then
        current.load_failed = true
        self:showError(self:errorText(err, status, "search"))
        return nil
    end
    current.load_failed = nil
    if append then
        for _, document in ipairs(page.documents) do
            table.insert(current.documents, document)
        end
        current.next_cursor = page.next_cursor
        current.scanned = current.scanned + page.scanned
    else
        current.documents = page.documents
        current.next_cursor = page.next_cursor
        current.scanned = page.scanned
    end
    return current
end

function Browser:showLinkSearchDialog(local_book, menu)
    if self.is_configured and not self.is_configured() then
        self:showError("Configure your Readwise access token before linking a book.")
        return
    end
    if type(local_book) ~= "table" or type(local_book.filepath) ~= "string" then
        self:showError("Open a local book before linking it to Reader.")
        return
    end

    local dialog
    dialog = InputDialog:new{
        title = "Find Reader book to link",
        input = local_book.title or "",
        input_hint = "Title or author",
        description = "The local filename is only a search suggestion. Select the exact Reader book; no automatic title match is made.",
        buttons = {
            {
                {
                    text = "Cancel",
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = "Search",
                    is_enter_default = true,
                    callback = function()
                        local query = trim(dialog:getInputText())
                        if query == "" then
                            self:showError("Enter a title or author.")
                            return
                        end
                        UIManager:close(dialog)
                        self.link_search = {
                            local_book = local_book,
                            query = query,
                            documents = {},
                            scanned = 0,
                        }
                        self:loadLinkSearch(false)
                        if menu then replaceMenuItems(menu, self:getLinkSearchItems()) end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Browser:selectionCount()
    local count = 0
    for _ in pairs(self.selected) do
        count = count + 1
    end
    return count
end

function Browser:selectAll(documents)
    for _, document in ipairs(documents) do
        self.selected[document.id] = document
    end
end

function Browser:selectedDocuments()
    local documents = {}
    for _, document in pairs(self.selected) do
        table.insert(documents, document)
    end
    table.sort(documents, function(left, right)
        return (left.title or "") < (right.title or "")
    end)
    return documents
end

function Browser:formatDetails(document)
    local downloaded = self:getDownloadedLookup()[document.id] and "Yes" or "No"
    local lines = { document.title }
    local fields = {
        { "Author", document.author },
        { "Site", document.site_name },
        { "Category", document.category },
        { "Location", LOCATION_LABELS[document.location] or document.location },
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
    return table.concat(lines, "\n\n")
end

function Browser:applyDownloadResult(result)
    if not result then
        return
    end
    for id in pairs(result.completed_ids or {}) do
        self.selected[id] = nil
    end
    for id in pairs(result.downloaded_ids or {}) do
        self:getDownloadedLookup()[id] = true
    end
end

function Browser:showDownloadSummary(result)
    if not result or result.cancelled then
        return
    end
    UIManager:show(InfoMessage:new{
        text = string.format(
            "%s\nDownloaded: %d\nAlready downloaded: %d\nSkipped: %d\nFailed: %d",
            result.aborted and "Download cancelled. Finished articles were kept:" or "Download complete:",
            result.downloaded or 0,
            result.already_downloaded or 0,
            result.skipped or 0,
            result.failed or 0),
    })
end

function Browser:download(document_list, menu)
    -- Run the whole download inside a coroutine so the progress dialog's Cancel
    -- button can be dispatched between articles. Result handling stays inside
    -- the wrap: the call returns at the first yield, so anything left outside
    -- would run before the download had finished.
    Trapper:wrap(function()
        local result = self.download_documents(document_list)
        self:applyDownloadResult(result)
        self:showDownloadSummary(result)
        if menu then
            menu:updateItems()
        end
    end)
end

function Browser:showDocumentInfo(document, menu)
    if self:getDownloadedLookup()[document.id] then
        -- Direct file opening is intentionally omitted until the installed
        -- KOReader build's supported API can be verified.
        UIManager:show(InfoMessage:new{ text = self:formatDetails(document) })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = self:formatDetails(document),
        ok_text = "Download",
        ok_callback = function()
            self:download({ document }, menu)
        end,
    })
end

function Browser:downloadSelected(menu)
    local documents = self:selectedDocuments()
    if #documents == 0 then
        self:showError("Select at least one document first.")
        return
    end
    UIManager:show(ConfirmBox:new{
        text = string.format("Download %d selected document(s)?", #documents),
        ok_text = "Download",
        ok_callback = function()
            self:download(documents, menu)
        end,
    })
end

function Browser:documentListItems(documents, options)
    options = options or {}
    local items = {
        {
            text = "Select all",
            enabled_func = function() return #documents > 0 end,
            keep_menu_open = true,
            callback = function(menu)
                self:selectAll(documents)
                if menu then menu:updateItems() end
            end,
        },
        {
            text = "Clear selection",
            enabled_func = function() return self:selectionCount() > 0 end,
            keep_menu_open = true,
            callback = function(menu)
                self.selected = {}
                if menu then menu:updateItems() end
            end,
        },
        {
            text_func = function()
                return string.format("Download selected (%d)", self:selectionCount())
            end,
            enabled_func = function() return self:selectionCount() > 0 end,
            keep_menu_open = true,
            separator = true,
            callback = function(menu) self:downloadSelected(menu) end,
        },
    }

    for _, document in ipairs(documents) do
        local row_document = document
        table.insert(items, {
            text_func = function() return self:rowText(row_document, options.show_location) end,
            keep_menu_open = true,
            callback = function(menu)
                if self.selected[row_document.id] then
                    self.selected[row_document.id] = nil
                else
                    self.selected[row_document.id] = row_document
                end
                if menu then menu:updateItems() end
            end,
            hold_callback = function(menu)
                self:showDocumentInfo(row_document, menu)
            end,
        })
    end
    return items
end

function Browser:getDocumentItems(location)
    local page = self.pages[location] or self:load(location, false)
    if not page then
        return {
            { text = "Retry", callback = function(menu)
                local page = self:load(location, false)
                if menu and page then replaceMenuItems(menu, self:getDocumentItems(location)) end
            end },
        }
    end

    local items = self:documentListItems(page.documents)
    if #page.documents == 0 then
        table.insert(items, { text = "No documents in this location.", enabled = false })
    end
    if page.next_cursor then
        table.insert(items, {
            text = "Load more",
            keep_menu_open = true,
            callback = function(menu)
                self:load(location, true)
                if menu then replaceMenuItems(menu, self:getDocumentItems(location)) end
            end,
        })
    end
    return items
end

function Browser:getSearchItems()
    local search = self.search
    if not search then
        return {}
    end
    local items = self:documentListItems(search.documents, { show_location = true })
    table.insert(items, 1, {
        text = "New search…",
        keep_menu_open = true,
        separator = true,
        callback = function(menu) self:showSearchDialog(menu) end,
    })
    if #search.documents == 0 then
        local status = search.load_failed
            and "Search failed. No results were changed."
            or search.next_cursor
            and string.format("No matches in %d scanned documents yet.", search.scanned)
            or string.format("No matches in %d scanned documents.", search.scanned)
        table.insert(items, { text = status, enabled = false })
    end
    if search.load_failed then
        table.insert(items, {
            text = "Retry search page",
            keep_menu_open = true,
            callback = function(menu)
                self:loadSearch(search.scanned > 0)
                if menu then replaceMenuItems(menu, self:getSearchItems()) end
            end,
        })
    end
    if search.next_cursor and not search.load_failed then
        table.insert(items, {
            text = string.format("Search next page (%d scanned)", search.scanned),
            keep_menu_open = true,
            callback = function(menu)
                self:loadSearch(true)
                if menu then replaceMenuItems(menu, self:getSearchItems()) end
            end,
        })
    end
    return items
end

function Browser:showSearchDialog(menu)
    if self.is_configured and not self.is_configured() then
        self:showError("Configure your Readwise access token before searching Reader.")
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = "Search Reader library",
        input = self.search and self.search.query or "",
        input_hint = "Title, author, site, summary, or tag",
        description = "Metadata-only search. Full document text is not searched.",
        buttons = {
            {
                {
                    text = "Cancel",
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = "Search",
                    is_enter_default = true,
                    callback = function()
                        local query = trim(dialog:getInputText())
                        if query == "" then
                            self:showError("Enter a search term.")
                            return
                        end
                        UIManager:close(dialog)
                        self.search = { query = query, documents = {}, scanned = 0 }
                        self.selected = {}
                        self:loadSearch(false)
                        if menu then replaceMenuItems(menu, self:getSearchItems()) end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Browser:getLocationItems()
    self.pages = {}
    self.downloaded_lookup = nil
    self.selected = {}
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

function Browser:loadView(view_key, append)
    if self.is_configured and not self.is_configured() then
        self:showError("Configure your Readwise access token before browsing Reader.")
        return nil
    end
    local current = self.views[view_key]
    local cursor = append and current and current.next_cursor or nil
    if append and not cursor then
        return current
    end

    self.show_progress(append and "Loading the next page…" or "Scanning your Reader library…")
    local page, err, status = self.reader_api:viewMetadata(view_key, cursor)
    self.hide_progress()
    if not page then
        self.views[view_key] = self.views[view_key] or { documents = {}, scanned = 0 }
        self.views[view_key].load_failed = true
        self:showError(self:errorText(err, status, "load"))
        return nil
    end

    if append and current then
        for _, document in ipairs(page.documents) do
            table.insert(current.documents, document)
        end
        current.next_cursor = page.next_cursor
        current.scanned = current.scanned + page.scanned
        current.load_failed = nil
    else
        self.views[view_key] = { documents = page.documents, next_cursor = page.next_cursor, scanned = page.scanned }
    end
    return self.views[view_key]
end

function Browser:getViewItems(view_key)
    local current = self.views[view_key] or self:loadView(view_key, false)
    if not current then
        return {
            { text = "Retry", callback = function(menu)
                local page = self:loadView(view_key, false)
                if menu and page then replaceMenuItems(menu, self:getViewItems(view_key)) end
            end },
        }
    end

    local items = self:documentListItems(current.documents, { show_location = true })
    if #current.documents == 0 then
        local status = current.load_failed
            and "Could not load this view. No results were changed."
            or current.next_cursor
            and string.format("No matches in %d scanned document(s) yet.", current.scanned)
            or string.format("No matches in %d scanned document(s).", current.scanned)
        table.insert(items, { text = status, enabled = false })
    end
    if current.load_failed then
        table.insert(items, {
            text = "Retry",
            keep_menu_open = true,
            callback = function(menu)
                self:loadView(view_key, current.scanned > 0)
                if menu then replaceMenuItems(menu, self:getViewItems(view_key)) end
            end,
        })
    end
    if current.next_cursor and not current.load_failed then
        table.insert(items, {
            text = string.format("Load more (%d scanned)", current.scanned),
            keep_menu_open = true,
            callback = function(menu)
                self:loadView(view_key, true)
                if menu then replaceMenuItems(menu, self:getViewItems(view_key)) end
            end,
        })
    end
    return items
end

function Browser:getViewsMenuItems()
    self.views = {}
    self.downloaded_lookup = nil
    self.selected = {}
    local items = {}
    for _, view in ipairs(VIEWS) do
        local view_key = view.key
        table.insert(items, {
            text = view.text,
            sub_item_table_func = function()
                return self:getViewItems(view_key)
            end,
        })
    end
    return items
end

return Browser
