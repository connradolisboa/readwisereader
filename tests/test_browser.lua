package.path = (os.getenv("PLUGIN_PATH") or "readwisereader.koplugin") .. "/?.lua;" .. package.path

-- Stub the KOReader widgets browser.lua requires; these tests only exercise
-- the menu builders and their in-memory state.
local function widget()
    return { new = function(_, o) return o end }
end
package.preload["ui/widget/confirmbox"] = widget
package.preload["ui/widget/infomessage"] = widget
package.preload["ui/widget/inputdialog"] = widget
package.preload["ui/trapper"] = function() return {} end
package.preload["ui/uimanager"] = function() return { show = function() end } end

local Browser = require("ui/browser")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %-46s got=%s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-46s %s", name, tostring(got)))
    end
end

local function newBrowser()
    local calls = { list = 0, view = 0 }
    local doc = { id = "doc1", title = "Doc", location = "new" }
    local browser = Browser:new{
        reader_api = {
            listMetadata = function()
                calls.list = calls.list + 1
                return { documents = { doc } }
            end,
            viewMetadata = function()
                calls.view = calls.view + 1
                return { documents = { doc }, scanned = 1 }
            end,
        },
        downloaded_ids = function() return {} end,
        download_documents = function() end,
        show_progress = function() end,
        hide_progress = function() end,
    }
    return browser, calls
end

local function findRow(items, prefix)
    for _, item in ipairs(items) do
        local text = item.text_func and item.text_func() or item.text
        if text and text:sub(1, #prefix) == prefix then return item end
    end
end

-- Launchers such as ZenOS re-run every parent builder after a row tap. That
-- must not clear the selection or refetch the list.
do
    local browser, calls = newBrowser()
    local inbox = browser:getLocationItems()[1]
    local items = inbox.sub_item_table_func()
    findRow(items, "[ ] Doc").callback(nil)
    check("location tap selects", browser:selectionCount(), 1)

    browser:getLocationItems()
    items = browser:getLocationItems()[1].sub_item_table_func()
    check("location rebuild keeps selection", browser:selectionCount(), 1)
    check("location rebuild uses cached page", calls.list, 1)
    check("location row still checked", findRow(items, "[x] Doc") ~= nil, true)

    findRow(items, "Refresh list").callback(nil)
    check("refresh list refetches", calls.list, 2)
    check("refresh list keeps selection", browser:selectionCount(), 1)
end

do
    local browser, calls = newBrowser()
    local items = browser:getViewsMenuItems()[1].sub_item_table_func()
    findRow(items, "[ ] Doc").callback(nil)
    browser:getViewsMenuItems()
    browser:getViewsMenuItems()[1].sub_item_table_func()
    check("view rebuild keeps selection", browser:selectionCount(), 1)
    check("view rebuild uses cached page", calls.view, 1)
end

-- Podcasts and audiobooks never list; videos list unless show_videos is off.
do
    local show_videos = true
    local browser = Browser:new{
        reader_api = {
            listMetadata = function()
                return { documents = {
                    { id = "a", title = "Article", category = "article" },
                    { id = "v", title = "Video", category = "video" },
                    { id = "p", title = "Podcast", category = "podcast" },
                    { id = "b", title = "Audiobook", category = "audiobook" },
                } }
            end,
        },
        downloaded_ids = function() return {} end,
        download_documents = function() end,
        show_videos = function() return show_videos end,
        show_progress = function() end,
        hide_progress = function() end,
    }
    local function rows()
        local items = browser:getLocationItems()[1].sub_item_table_func()
        return findRow(items, "[ ] Article") ~= nil, findRow(items, "[ ] Video") ~= nil,
            findRow(items, "[ ] Podcast") ~= nil, findRow(items, "[ ] Audiobook") ~= nil
    end
    local article, video, podcast, audiobook = rows()
    check("article listed", article, true)
    check("video listed by default", video, true)
    check("podcast hidden", podcast, false)
    check("audiobook hidden", audiobook, false)

    show_videos = false
    article, video = rows()
    check("video hidden when setting off", video, false)
    check("article still listed", article, true)

    browser:getLocationItems()[1].sub_item_table_func()[1].callback(nil)
    check("select all skips hidden", browser:selectionCount(), 1)
end

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all browser tests passed")
