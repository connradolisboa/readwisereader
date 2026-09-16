-- Read-only text-first browser for Readwise highlights: local-filter search
-- across the v2 highlights list, and the Daily Review endpoint. This never
-- creates, edits, or exports anything -- api/highlights.lua's export pipeline
-- is untouched and unrelated.
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")

local HighlightsBrowser = {}
HighlightsBrowser.__index = HighlightsBrowser

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

function HighlightsBrowser:new(options)
    assert(type(options) == "table" and options.highlights_api, "Highlights read API required")
    return setmetatable({
        highlights_api = options.highlights_api,
        is_configured = options.is_configured,
        show_progress = options.show_progress,
        hide_progress = options.hide_progress,
        search = nil,
        daily_review = nil,
        -- Session-only cache: id -> book table, or `false` for "fetch failed,
        -- do not retry every time this row is redrawn".
        book_cache = {},
    }, self)
end

function HighlightsBrowser:showError(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 5 })
end

function HighlightsBrowser:errorText(err, status, action)
    if err == "network_error" then
        return "Highlights " .. action .. " requires a network connection."
    end
    if status == 401 or status == 403 then
        return "Readwise authentication failed. Check your access token."
    end
    return "Could not " .. action .. " highlights. Please check your token and connection."
end

function HighlightsBrowser:rowText(highlight)
    local snippet = highlight.text or "(no text)"
    if #snippet > 140 then
        snippet = snippet:sub(1, 140) .. "…"
    end
    local book = self.book_cache[highlight.book_id]
    local title = highlight.title or (book and book.title)
        or (highlight.book_id and ("Book #" .. tostring(highlight.book_id)) or nil)
    local author = highlight.author or (book and book.author)
    local attribution
    if title and author then
        attribution = title .. " — " .. author
    else
        attribution = title or author
    end
    return attribution and (snippet .. "\n" .. attribution) or snippet
end

function HighlightsBrowser:formatDetails(highlight)
    local lines = { highlight.text or "(no text)" }
    if highlight.note then
        table.insert(lines, "Note: " .. highlight.note)
    end
    local book = self.book_cache[highlight.book_id]
    local title = highlight.title or (book and book.title)
    local author = highlight.author or (book and book.author)
    if title then table.insert(lines, "From: " .. title) end
    if author then table.insert(lines, "By: " .. author) end
    if highlight.highlighted_at then table.insert(lines, "Highlighted: " .. highlight.highlighted_at) end
    return table.concat(lines, "\n\n")
end

-- Fetches the book title/author on demand, once per session per book, only
-- when the user actually opens a highlight's details.
function HighlightsBrowser:showHighlightDetails(highlight, menu)
    if highlight.book_id and self.book_cache[highlight.book_id] == nil then
        self.show_progress("Loading book details…")
        local book = self.highlights_api:getBook(highlight.book_id)
        self.hide_progress()
        self.book_cache[highlight.book_id] = book or false
        if menu then menu:updateItems() end
    end
    UIManager:show(InfoMessage:new{ text = self:formatDetails(highlight) })
end

function HighlightsBrowser:highlightItems(highlights)
    local items = {}
    for _, highlight in ipairs(highlights) do
        local row_highlight = highlight
        table.insert(items, {
            text_func = function() return self:rowText(row_highlight) end,
            keep_menu_open = true,
            callback = function(menu) self:showHighlightDetails(row_highlight, menu) end,
        })
    end
    return items
end

-- Search ------------------------------------------------------------------

function HighlightsBrowser:loadSearch(append)
    local current = self.search
    if not current then
        return nil
    end
    local cursor = append and current.next_page or nil
    if append and not cursor then
        return current
    end

    self.show_progress(append and "Searching the next page of highlights…" or "Searching highlights…")
    local page, err, status = self.highlights_api:searchHighlights(current.query, cursor)
    self.hide_progress()
    if not page then
        current.load_failed = true
        self:showError(self:errorText(err, status, "search"))
        return nil
    end
    current.load_failed = nil

    if append then
        for _, highlight in ipairs(page.highlights) do
            table.insert(current.highlights, highlight)
        end
        current.next_page = page.next_page
        current.scanned = current.scanned + page.scanned
    else
        current.highlights = page.highlights
        current.next_page = page.next_page
        current.scanned = page.scanned
    end
    return current
end

function HighlightsBrowser:getSearchItems()
    local search = self.search
    if not search then
        return {}
    end
    local items = {
        {
            text = "New search…",
            keep_menu_open = true,
            separator = true,
            callback = function(menu) self:showSearchDialog(menu) end,
        },
    }
    for _, item in ipairs(self:highlightItems(search.highlights)) do
        table.insert(items, item)
    end
    if #search.highlights == 0 then
        local status = search.load_failed
            and "Search failed. No results were changed."
            or search.next_page
            and string.format("No matches in %d scanned highlight(s) yet.", search.scanned)
            or string.format("No matches in %d scanned highlight(s).", search.scanned)
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
    if search.next_page and not search.load_failed then
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

function HighlightsBrowser:showSearchDialog(menu)
    if self.is_configured and not self.is_configured() then
        self:showError("Configure your Readwise access token before searching highlights.")
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = "Search highlights",
        input = self.search and self.search.query or "",
        input_hint = "Text or note",
        description = "Scans your highlights one page at a time and filters text and notes locally. "
            .. "Book title/author only match when already shown on the highlight.",
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
                        self.search = { query = query, highlights = {}, scanned = 0 }
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

-- Daily Review --------------------------------------------------------------

function HighlightsBrowser:loadDailyReview()
    if self.is_configured and not self.is_configured() then
        self:showError("Configure your Readwise access token before loading Daily Review.")
        return nil
    end
    self.show_progress("Loading Daily Review…")
    local review, err, status = self.highlights_api:dailyReview()
    self.hide_progress()
    if not review then
        self:showError(self:errorText(err, status, "load"))
        return nil
    end
    self.daily_review = review
    return review
end

function HighlightsBrowser:getDailyReviewItems()
    local review = self.daily_review or self:loadDailyReview()
    if not review then
        return {
            { text = "Retry", callback = function(menu)
                local reloaded = self:loadDailyReview()
                if menu and reloaded then replaceMenuItems(menu, self:getDailyReviewItems()) end
            end },
        }
    end

    local items = {
        {
            text = "Refresh",
            keep_menu_open = true,
            separator = true,
            callback = function(menu)
                self.daily_review = nil
                local reloaded = self:loadDailyReview()
                if menu and reloaded then replaceMenuItems(menu, self:getDailyReviewItems()) end
            end,
        },
    }
    for _, item in ipairs(self:highlightItems(review.highlights)) do
        table.insert(items, item)
    end
    if #review.highlights == 0 then
        table.insert(items, { text = "No highlights in today's Daily Review.", enabled = false })
    end
    return items
end

return HighlightsBrowser
