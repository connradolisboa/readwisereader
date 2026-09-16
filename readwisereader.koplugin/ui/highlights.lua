-- Read-only browser for Readwise highlights, grouped the way Readwise's own
-- highlights view is: by category (Books/Articles/Tweets/Podcasts), then by
-- book, then by highlight. A highlight opens in a large scrollable viewer
-- with Previous/Next paging and a jump into its book's full highlight list,
-- rather than a size-constrained pop-up. Search and Daily Review reuse the
-- same viewer, scoped to their own result list. This never creates, edits, or
-- exports anything -- api/highlights.lua's export pipeline is untouched.
--
-- TextViewer's `buttons_table` field and its constructor shape are used here
-- unverified against an installed KOReader build (see docs/ARCHITECTURE.md:
-- "KOReader source is not available locally"). Construction is wrapped in
-- pcall, matching ui/downloadprogress.lua's precedent, so a mismatch falls
-- back to a plain InfoMessage instead of crashing the menu.
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local logger = require("logger")

local HighlightsBrowser = {}
HighlightsBrowser.__index = HighlightsBrowser

-- The four documented v2 categories (see api/highlights.lua's CATEGORY_MAP).
local CATEGORIES = {
    { key = "books", text = "Books" },
    { key = "articles", text = "Articles" },
    { key = "tweets", text = "Tweets" },
    { key = "podcasts", text = "Podcasts" },
}

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
        category_books = {},
        book_highlights = {},
        -- Session-only cache: book_id -> book table, or `false` for "fetch
        -- failed, do not retry every time this row is redrawn".
        book_cache = {},
        active_viewer = nil,
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

-- Top-level menu ------------------------------------------------------------

function HighlightsBrowser:getMenuItems()
    self.category_books = {}
    self.book_highlights = {}
    local items = {}
    for _, category in ipairs(CATEGORIES) do
        local category_key = category.key
        table.insert(items, {
            text = category.text,
            sub_item_table_func = function() return self:getCategoryItems(category_key) end,
        })
    end
    table.insert(items, {
        text = "Search Highlights",
        keep_menu_open = true,
        separator = true,
        callback = function(touchmenu_instance) self:showSearchDialog(touchmenu_instance) end,
    })
    table.insert(items, {
        text = "Daily Review",
        sub_item_table_func = function() return self:getDailyReviewItems() end,
    })
    return items
end

-- Category -> books ----------------------------------------------------------

function HighlightsBrowser:getCategoryState(category_key)
    local state = self.category_books[category_key]
    if not state then
        state = { books = {}, next_page = 1 }
        self.category_books[category_key] = state
    end
    return state
end

function HighlightsBrowser:loadCategoryBooks(category_key, append)
    local state = self:getCategoryState(category_key)
    if append and not state.next_page then
        return state
    end
    if not append and #state.books > 0 then
        return state
    end
    if self.is_configured and not self.is_configured() then
        self:showError("Configure your Readwise access token before browsing highlights.")
        return state
    end
    local cursor = append and state.next_page or 1
    self.show_progress(append and "Loading more books…" or "Loading books…")
    local page, err, status = self.highlights_api:listBooksPage(category_key, cursor)
    self.hide_progress()
    if not page then
        state.load_failed = true
        self:showError(self:errorText(err, status, "load"))
        return state
    end
    state.load_failed = nil
    for _, book in ipairs(page.books) do
        table.insert(state.books, book)
    end
    state.next_page = page.next_page
    return state
end

function HighlightsBrowser:bookRowText(book)
    local parts = {}
    if book.author then
        table.insert(parts, book.author)
    end
    if type(book.num_highlights) == "number" then
        table.insert(parts, book.num_highlights .. (book.num_highlights == 1 and " highlight" or " highlights"))
    end
    local subtitle = table.concat(parts, " · ")
    return subtitle ~= "" and (book.title .. "\n" .. subtitle) or book.title
end

function HighlightsBrowser:getCategoryItems(category_key)
    local state = self:loadCategoryBooks(category_key, false)
    local items = {}
    for _, book in ipairs(state.books) do
        local row_book = book
        table.insert(items, {
            text_func = function() return self:bookRowText(row_book) end,
            sub_item_table_func = function() return self:getBookHighlightsItems(row_book) end,
        })
    end
    if #state.books == 0 then
        table.insert(items, {
            text = state.load_failed and "Could not load books." or "No highlighted books in this category yet.",
            enabled = false,
        })
    end
    if state.load_failed then
        table.insert(items, {
            text = "Retry",
            keep_menu_open = true,
            callback = function(menu)
                self:loadCategoryBooks(category_key, #state.books > 0)
                if menu then replaceMenuItems(menu, self:getCategoryItems(category_key)) end
            end,
        })
    end
    if state.next_page and not state.load_failed then
        table.insert(items, {
            text = string.format("Load more (%d loaded)", #state.books),
            keep_menu_open = true,
            callback = function(menu)
                self:loadCategoryBooks(category_key, true)
                if menu then replaceMenuItems(menu, self:getCategoryItems(category_key)) end
            end,
        })
    end
    return items
end

-- Book -> highlights ----------------------------------------------------------

function HighlightsBrowser:getBookState(book)
    local state = self.book_highlights[book.id]
    if not state then
        state = { highlights = {}, next_page = 1, book = book }
        self.book_highlights[book.id] = state
    end
    return state
end

function HighlightsBrowser:loadBookHighlights(book, append)
    local state = self:getBookState(book)
    if append and not state.next_page then
        return state
    end
    if not append and #state.highlights > 0 then
        return state
    end
    local cursor = append and state.next_page or 1
    self.show_progress(append and "Loading more highlights…" or "Loading highlights…")
    local page, err, status = self.highlights_api:listBookHighlightsPage(book.id, cursor)
    self.hide_progress()
    if not page then
        state.load_failed = true
        self:showError(self:errorText(err, status, "load"))
        return state
    end
    state.load_failed = nil
    for _, highlight in ipairs(page.highlights) do
        table.insert(state.highlights, highlight)
    end
    state.next_page = page.next_page
    return state
end

function HighlightsBrowser:highlightRowText(highlight)
    local snippet = highlight.text or "(no text)"
    if #snippet > 100 then
        snippet = snippet:sub(1, 100) .. "…"
    end
    local parts = { snippet }
    local attribution
    if highlight.title and highlight.author then
        attribution = highlight.title .. " — " .. highlight.author
    else
        attribution = highlight.title or highlight.author
    end
    if attribution then
        table.insert(parts, attribution)
    end
    if highlight.note then
        table.insert(parts, "(has a note)")
    end
    return table.concat(parts, "\n")
end

function HighlightsBrowser:getBookHighlightsItems(book)
    local state = self:loadBookHighlights(book, false)
    local items = {}
    for index, highlight in ipairs(state.highlights) do
        local row_index = index
        table.insert(items, {
            text_func = function() return self:highlightRowText(highlight) end,
            keep_menu_open = true,
            callback = function()
                self:showHighlightViewer(self:bookContext(book), row_index)
            end,
        })
    end
    if #state.highlights == 0 then
        table.insert(items, {
            text = state.load_failed and "Could not load highlights." or "No highlights in this book yet.",
            enabled = false,
        })
    end
    if state.load_failed then
        table.insert(items, {
            text = "Retry",
            keep_menu_open = true,
            callback = function(menu)
                self:loadBookHighlights(book, #state.highlights > 0)
                if menu then replaceMenuItems(menu, self:getBookHighlightsItems(book)) end
            end,
        })
    end
    if state.next_page and not state.load_failed then
        table.insert(items, {
            text = string.format("Load more (%d loaded)", #state.highlights),
            keep_menu_open = true,
            callback = function(menu)
                self:loadBookHighlights(book, true)
                if menu then replaceMenuItems(menu, self:getBookHighlightsItems(book)) end
            end,
        })
    end
    return items
end

-- Reading contexts ------------------------------------------------------------
-- A context is the list a Previous/Next pair walks through. `items` may be a
-- table shared with a cache above, growing in place as more pages load, so
-- `has_more`/`load_more` are closures rather than a plain next-page field.

function HighlightsBrowser:bookContext(book)
    local state = self:getBookState(book)
    return {
        title = book.title or "Book",
        book = book,
        items = state.highlights,
        has_more = function() return state.next_page ~= nil end,
        load_more = function()
            local before = #state.highlights
            local updated = self:loadBookHighlights(book, true)
            return not updated.load_failed and #state.highlights > before
        end,
        show_view_all = false,
    }
end

function HighlightsBrowser:searchContext()
    local search = self.search
    return {
        title = "Search: " .. search.query,
        items = search.highlights,
        has_more = function() return search.next_page ~= nil end,
        load_more = function() return self:loadSearch(true) ~= nil end,
        show_view_all = true,
    }
end

function HighlightsBrowser:reviewContext()
    return {
        title = "Daily Review",
        items = self.daily_review.highlights,
        has_more = function() return false end,
        load_more = function() return false end,
        show_view_all = true,
    }
end

function HighlightsBrowser:ensureContextIndex(context, index)
    while context.items[index] == nil and context.has_more() do
        if not context.load_more() then
            return false
        end
    end
    return context.items[index] ~= nil
end

-- Fetches a book's title/author once per session, only when a highlight with
-- neither of its own (plain search results) is actually opened.
function HighlightsBrowser:ensureBookCached(book_id)
    if book_id == nil or self.book_cache[book_id] ~= nil then
        return
    end
    self.show_progress("Loading book details…")
    local book = self.highlights_api:getBook(book_id)
    self.hide_progress()
    self.book_cache[book_id] = book or false
end

function HighlightsBrowser:formatHighlightBody(highlight, context)
    local book = self.book_cache[highlight.book_id]
    local title = highlight.title or (context.book and context.book.title) or (book and book.title)
    local author = highlight.author or (context.book and context.book.author) or (book and book.author)
    local lines = {}
    if title or author then
        if title and author then
            table.insert(lines, title .. " — " .. author)
        else
            table.insert(lines, title or author)
        end
        table.insert(lines, "")
    end
    table.insert(lines, highlight.text or "(no text)")
    if highlight.note then
        table.insert(lines, "")
        table.insert(lines, "Note: " .. highlight.note)
    end
    if highlight.highlighted_at then
        table.insert(lines, "")
        table.insert(lines, "Highlighted: " .. highlight.highlighted_at)
    end
    return table.concat(lines, "\n")
end

function HighlightsBrowser:closeHighlightViewer()
    if self.active_viewer then
        UIManager:close(self.active_viewer)
        self.active_viewer = nil
    end
end

-- Large, scrollable, near-fullscreen highlight display with Previous/Next
-- paging through `context.items` (loading more pages on demand) and, unless
-- already inside a book's own list, a jump into that highlight's full book.
function HighlightsBrowser:showHighlightViewer(context, index)
    if not self:ensureContextIndex(context, index) then
        self:showError("Could not load that highlight.")
        return
    end
    local highlight = context.items[index]
    if highlight.book_id and not highlight.title and not context.book then
        self:ensureBookCached(highlight.book_id)
    end

    local buttons = {}
    local nav_row = {}
    if index > 1 then
        table.insert(nav_row, {
            text = "◀ Previous",
            callback = function()
                self:closeHighlightViewer()
                self:showHighlightViewer(context, index - 1)
            end,
        })
    end
    if context.items[index + 1] ~= nil or context.has_more() then
        table.insert(nav_row, {
            text = "Next ▶",
            callback = function()
                self:closeHighlightViewer()
                self:showHighlightViewer(context, index + 1)
            end,
        })
    end
    if #nav_row > 0 then
        table.insert(buttons, nav_row)
    end
    if context.show_view_all and highlight.book_id then
        table.insert(buttons, {
            {
                text = "View all highlights in this book",
                callback = function()
                    self:closeHighlightViewer()
                    local cached_book = self.book_cache[highlight.book_id]
                    self:showHighlightViewer(self:bookContext{
                        id = highlight.book_id,
                        title = highlight.title or (cached_book and cached_book.title),
                        author = highlight.author or (cached_book and cached_book.author),
                    }, 1)
                end,
            },
        })
    end

    local position = context.has_more() and (index .. "/" .. #context.items .. "+") or (index .. "/" .. #context.items)
    local title = context.title .. " (" .. position .. ")"
    local text = self:formatHighlightBody(highlight, context)

    self:closeHighlightViewer()
    local ok, viewer = pcall(function()
        return TextViewer:new{
            title = title,
            title_multilines = true,
            text = text,
            justified = true,
            width = math.floor(Screen:getWidth() * 0.95),
            height = math.floor(Screen:getHeight() * 0.9),
            buttons_table = buttons,
        }
    end)
    if ok and viewer then
        self.active_viewer = viewer
        UIManager:show(viewer)
    else
        logger.warn("ReadwiseReader:showHighlightViewer: TextViewer construction failed, falling back", viewer)
        UIManager:show(InfoMessage:new{ text = title .. "\n\n" .. text })
    end
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
    for index, highlight in ipairs(search.highlights) do
        local row_index = index
        table.insert(items, {
            text_func = function() return self:highlightRowText(highlight) end,
            keep_menu_open = true,
            callback = function()
                self:showHighlightViewer(self:searchContext(), row_index)
            end,
        })
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
    for index, highlight in ipairs(review.highlights) do
        local row_index = index
        table.insert(items, {
            text_func = function() return self:highlightRowText(highlight) end,
            keep_menu_open = true,
            callback = function()
                self:showHighlightViewer(self:reviewContext(), row_index)
            end,
        })
    end
    if #review.highlights == 0 then
        table.insert(items, { text = "No highlights in today's Daily Review.", enabled = false })
    end
    return items
end

return HighlightsBrowser
