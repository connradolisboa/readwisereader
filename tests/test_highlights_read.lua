package.path = (os.getenv("PLUGIN_PATH") or "readwisereader.koplugin") .. "/?.lua;" .. package.path
local HighlightsRead = require("api/highlights_read")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %-46s got=%s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-46s %s", name, tostring(got)))
    end
end

print("== normalization ==")
local normalized = HighlightsRead.normalizeHighlight({
    id = 1,
    text = "A highlighted line",
    note = "",
    book_id = 42,
    highlighted_at = "2023-11-14T22:13:21Z",
})
check("keeps text", normalized.text, "A highlighted line")
check("empty note becomes nil", normalized.note, nil)
check("keeps book_id", normalized.book_id, 42)
check("rejects a highlight with no id", HighlightsRead.normalizeHighlight({ text = "x" }), nil)

print("\n== paginated listing ==")
local pages = {
    [1] = { results = { { id = 1, text = "first" }, { id = 2, text = "second" } }, next = "https://readwise.io/api/v2/highlights/?page=2" },
    [2] = { results = { { id = 3, text = "third" } }, next = nil },
}
local requested_endpoints = {}
local list_api = HighlightsRead:new{
    request = function(endpoint, method, body)
        table.insert(requested_endpoints, endpoint)
        check("list uses GET", method, "GET")
        check("list sends no body", body, nil)
        local page_number = tonumber(endpoint:match("page=(%d+)")) or 1
        return pages[page_number]
    end,
}
local page1 = list_api:listPage()
check("first page defaults to page 1", requested_endpoints[1]:find("page=1", 1, true) ~= nil, true)
check("first page has two highlights", #page1.highlights, 2)
check("first page reports a next page", page1.next_page, 2)
local page2 = list_api:listPage(page1.next_page)
check("second page has one highlight", #page2.highlights, 1)
check("last page has no next page", page2.next_page, nil)

print("\n== search scans one page and filters locally ==")
local search_pages = {
    [1] = { results = {
        { id = 1, text = "the quick fox" },
        { id = 2, text = "a slow turtle", note = "about patience" },
    }, next = "https://readwise.io/api/v2/highlights/?page=2" },
    [2] = { results = { { id = 3, text = "another quick one" } }, next = nil },
}
local search_api = HighlightsRead:new{
    request = function(endpoint)
        local page_number = tonumber(endpoint:match("page=(%d+)")) or 1
        return search_pages[page_number]
    end,
}
local search_page1 = search_api:searchHighlights("quick")
check("first page matches by text", #search_page1.highlights, 1)
check("scanned reports full page size", search_page1.scanned, 2)
check("next page is retained for Search next page", search_page1.next_page, 2)
local search_page2 = search_api:searchHighlights("quick", search_page1.next_page)
check("second page also matches", #search_page2.highlights, 1)
local note_page1 = search_api:searchHighlights("patience")
check("note text also matches", #note_page1.highlights, 1)

print("\n== books grouped by category ==")
local book_pages = {
    [1] = { results = {
        { id = 1, title = "On Agency", author = "Henrik Karlsson", category = "articles", num_highlights = 3 },
        { id = 2, title = "Untitled book", num_highlights = 0 },
    }, next = "https://readwise.io/api/v2/books/?category=articles&page=2" },
    [2] = { results = { { id = 3, title = "Another Article", num_highlights = 1 } }, next = nil },
}
local requested_book_endpoints = {}
local books_api = HighlightsRead:new{
    request = function(endpoint, method, body)
        table.insert(requested_book_endpoints, endpoint)
        check("books list uses GET", method, "GET")
        check("books list sends no body", body, nil)
        local page_number = tonumber(endpoint:match("page=(%d+)")) or 1
        return book_pages[page_number]
    end,
}
local books_page1 = books_api:listBooksPage("articles")
check("category is sent as a query param", requested_book_endpoints[1]:find("category=articles", 1, true) ~= nil, true)
check("first page has two books", #books_page1.books, 2)
check("book title is kept", books_page1.books[1].title, "On Agency")
check("missing title falls back to Untitled", books_page1.books[2].title, "Untitled book")
check("first page reports a next page", books_page1.next_page, 2)
local books_page2 = books_api:listBooksPage("articles", books_page1.next_page)
check("second page has one book", #books_page2.books, 1)
check("last books page has no next page", books_page2.next_page, nil)

print("\n== one book's highlights via the documented book_id filter ==")
local book_highlight_pages = {
    [1] = { results = { { id = 10, text = "first in book" }, { id = 11, text = "second in book" } },
        next = "https://readwise.io/api/v2/highlights/?book_id=1&page=2" },
    [2] = { results = { { id = 12, text = "third in book" } }, next = nil },
}
local requested_book_highlight_endpoints = {}
local book_highlights_api = HighlightsRead:new{
    request = function(endpoint)
        table.insert(requested_book_highlight_endpoints, endpoint)
        local page_number = tonumber(endpoint:match("page=(%d+)")) or 1
        return book_highlight_pages[page_number]
    end,
}
local book_highlights_page1 = book_highlights_api:listBookHighlightsPage(1)
check("book_id is sent as a query param", requested_book_highlight_endpoints[1]:find("book_id=1", 1, true) ~= nil, true)
check("first page has two highlights", #book_highlights_page1.highlights, 2)
check("first page reports a next page", book_highlights_page1.next_page, 2)
local book_highlights_page2 = book_highlights_api:listBookHighlightsPage(1, book_highlights_page1.next_page)
check("second page has one highlight", #book_highlights_page2.highlights, 1)
check("last page has no next page", book_highlights_page2.next_page, nil)

print("\n== book lookup ==")
local book_api = HighlightsRead:new{
    request = function(endpoint, method)
        check("book fetch uses GET", method, "GET")
        check("book endpoint", endpoint, "/books/42/")
        return { id = 42, title = "On Agency", author = "Henrik Karlsson" }
    end,
}
local book = book_api:getBook(42)
check("book title", book.title, "On Agency")
check("book author", book.author, "Henrik Karlsson")
check("missing book id is rejected", select(2, book_api:getBook(nil)), "missing_book_id")

print("\n== daily review ==")
local review_api = HighlightsRead:new{
    request = function(endpoint)
        check("review endpoint", endpoint, "/review/")
        return {
            review_id = 99,
            review_url = "https://readwise.io/reviews/99",
            highlights = {
                { id = 1, text = "reviewed line", title = "Some Book", author = "Some Author" },
            },
        }
    end,
}
local review = review_api:dailyReview()
check("review id", review.review_id, 99)
check("review url", review.review_url, "https://readwise.io/reviews/99")
check("review highlight count", #review.highlights, 1)
check("review highlight carries its own title", review.highlights[1].title, "Some Book")

print(failures == 0 and "\nALL PASS" or string.format("\n%d FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
