package.path = (os.getenv("PLUGIN_PATH") or "readwisereader.koplugin") .. "/?.lua;" .. package.path
local Links = require("library/local_links")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %-46s got=%s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-46s %s", name, tostring(got)))
    end
end

local document = {
    id = "01m0f0sf3faxh0qftse4r32m06",
    title = "On Agency",
    author = "Henrik Karlsson",
    source_url = "https://www.henrikkarlsson.xyz/p/agency",
    url = "https://read.readwise.io/read/01m0f0sf3faxh0qftse4r32m06",
    category = "epub",
    image_url = "https://example.test/cover.jpg",
}

print("== explicit local links ==")
local links = {}
local path = "/mnt/us/documents/On Agency.epub"
local link = Links.set(links, path, document)
check("link is stored", link ~= nil, true)
check("Reader id is retained", link.id, document.id)
check("Reader title is retained", link.title, document.title)
check("Reader author is retained", link.author, document.author)
check("Reader source URL is retained", link.source_url, document.source_url)
check("Reader read URL is retained", link.reader_url, document.url)
check("lookup uses exact local path", Links.get(links, path).id, document.id)
check("lookup retains the Reader read URL", Links.get(links, path).reader_url, document.url)
check("same filename in another folder is not linked", Links.get(links, "/mnt/us/books/On Agency.epub"), nil)
check("missing Reader id is rejected", Links.set(links, "/mnt/us/books/Bad.epub", { title = "Bad" }), nil)
check("remove existing link", Links.remove(links, path), true)
check("removed link no longer resolves", Links.get(links, path), nil)
check("remove missing link", Links.remove(links, path), false)

print(failures == 0 and "\nALL PASS" or string.format("\n%d FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
