-- Exercises the progress controller without KOReader, by stubbing the widget
-- modules it requires. The invariant that matters most here is that tick()
-- never yields: it runs inside a string.gsub callback during image fetching,
-- and LuaJIT cannot yield across that C-call boundary.
package.path = (os.getenv("PLUGIN_PATH") or "readwisereader.koplugin") .. "/?.lua;" .. package.path

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %-52s got=%s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-52s %s", name, tostring(got)))
    end
end

-- Minimal KOReader widget base: supports :extend{} and :new{} with init.
local Base = {}
Base.__index = Base
function Base:extend(subclass)
    subclass = subclass or {}
    subclass.__index = subclass
    return setmetatable(subclass, { __index = self })
end
function Base:new(instance)
    instance = instance or {}
    setmetatable(instance, { __index = self })
    if instance.init then instance:init() end
    return instance
end

local ui = { shown = {}, repaints = 0, ticks = {} }
local clock = { now = 1000 }

local function stubText()
    local T = Base:extend{}
    function T:init() self.text = self.text or "" end
    function T:setText(text) self.text = text end
    function T:getSize() return { w = 100, h = 20 } end
    return T
end

local function stubPlain()
    local P = Base:extend{}
    function P:getSize() return { w = 100, h = 20 } end
    return P
end

local ProgressWidgetStub = Base:extend{}
function ProgressWidgetStub:setPercentage(p) self.percentage = p end
function ProgressWidgetStub:getSize() return { w = 100, h = 16 } end

local ButtonStub = Base:extend{}
function ButtonStub:init() self.enabled = true end
function ButtonStub:disable() self.enabled = false end
function ButtonStub:getSize() return { w = 100, h = 30 } end

package.loaded["ffi/blitbuffer"] = { COLOR_WHITE = 1, COLOR_BLACK = 2 }
package.loaded["ui/widget/button"] = ButtonStub
package.loaded["ui/widget/container/centercontainer"] = stubPlain()
package.loaded["ui/widget/container/framecontainer"] = stubPlain()
package.loaded["ui/widget/container/inputcontainer"] = Base:extend{}
package.loaded["ui/widget/verticalgroup"] = stubPlain()
package.loaded["ui/widget/verticalspan"] = stubPlain()
package.loaded["ui/widget/progresswidget"] = ProgressWidgetStub
package.loaded["ui/widget/textwidget"] = stubText()
package.loaded["ui/geometry"] = Base:extend{}
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["ui/size"] = {
    padding = { small = 1, large = 2 }, margin = { small = 1, tiny = 1 },
    radius = { window = 1 }, border = { window = 1 },
}
package.loaded["device"] = {
    hasEinkScreen = function() return false end,
    screen = {
        getSize = function() return { w = 600, h = 800 } end,
        getWidth = function() return 600 end,
        scaleBySize = function(_, n) return n end,
    },
}
package.loaded["ui/uimanager"] = {
    show = function(_, w) ui.shown[w] = true end,
    close = function(_, w) ui.shown[w] = nil end,
    setDirty = function() end,
    forceRePaint = function() ui.repaints = ui.repaints + 1 end,
    nextTick = function(_, fn) table.insert(ui.ticks, fn) end,
}
package.loaded["logger"] = { warn = function() end, dbg = function() end, err = function() end }
package.loaded["socket"] = { gettime = function() return clock.now end }
package.loaded["util"] = {
    getFriendlySize = function(n)
        if n > 1000 * 1000 then return string.format("%.1f MB", n / 1000 / 1000) end
        if n > 1000 then return string.format("%.1f kB", n / 1000) end
        return string.format("%d B", n)
    end,
}

local Progress = require("ui/downloadprogress")

-- Drives the controller inside a coroutine and reports whether it suspended.
local function run(fn)
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co)
    if not ok then error(err, 0) end
    return co, coroutine.status(co) == "suspended"
end

local function advance(seconds) clock.now = clock.now + (seconds or 1) end

print("== construction ==")
local p
run(function() p = Progress.start{ title = "Downloading", total = 4 } end)
check("dialog is created", p ~= nil, true)
check("dialog is shown", ui.shown[p.dialog] ~= nil, true)
check("cancel enabled inside a coroutine", p.dialog.cancel_button.enabled, true)

local outside = Progress.start{ title = "x", total = 1 }
check("cancel disabled outside a coroutine", outside.dialog.cancel_button.enabled, false)
outside:close()

print("\n== tick never yields (gsub safety) ==")
local yielded
_, yielded = run(function()
    local prog = Progress.start{ title = "t", total = 2 }
    advance(10)
    prog:tick({ bytes = 500 })
end)
check("tick does not suspend the coroutine", yielded, false)
_, yielded = run(function()
    local prog = Progress.start{ title = "t", total = 2 }
    advance(10)
    prog:addBytes(500)
end)
check("addBytes does not suspend the coroutine", yielded, false)

print("\n== update yields so cancel can fire ==")
_, yielded = run(function()
    local prog = Progress.start{ title = "t", total = 2 }
    advance(10)
    prog:update({ done = 1, force = true })
end)
check("update suspends when it redraws", yielded, true)
_, yielded = run(function()
    local prog = Progress.start{ title = "t", total = 2 }
    prog.last_redraw = clock.now
    prog:update({ done = 1 })
end)
check("throttled update does not suspend", yielded, false)

print("\n== cancel handshake ==")
local prog, result
local co = coroutine.create(function()
    prog = Progress.start{ title = "t", total = 3 }
    advance(10)
    result = prog:update({ done = 0, force = true })
end)
coroutine.resume(co)
check("worker is parked awaiting a tick", coroutine.status(co), "suspended")
prog.dialog.cancel_button.callback()
check("cancel resumes the worker", coroutine.status(co), "dead")
check("update reports the cancellation", result, true)
check("isCancelled stays true", prog:isCancelled(), true)
check("later update short-circuits", prog:update({ done = 2, force = true }), true)
check("later tick short-circuits", prog:tick({ bytes = 1 }), true)
check("later addBytes short-circuits", prog:addBytes(10), true)
check("cancel button is disabled", prog.dialog.cancel_button.enabled, false)

print("\n== displayed figures ==")
local shown
run(function()
    shown = Progress.start{ title = "t", total = 5 }
    advance(10)
    shown:update({ done = 2, item = "An Article", force = true })
end)
check("headline counts from one", shown.dialog.headline_widget.text, "3 of 5 · 3 remaining")
check("current item is shown", shown.dialog.item_widget.text, "An Article")
check("bar tracks completed items", shown.dialog.progress_widget.percentage, 2 / 5)
check("zero bytes render", shown.dialog.detail_widget.text, "0 B downloaded")

run(function()
    advance(10)
    shown:tick({ bytes = 2500000 })
end)
check("bytes are humanized", shown.dialog.detail_widget.text, "2.5 MB downloaded")
run(function()
    advance(10)
    shown:addBytes(500000)
end)
check("addBytes accumulates", shown.dialog.detail_widget.text, "3.0 MB downloaded")

print("\n== final state and teardown ==")
run(function()
    advance(10)
    shown:update({ done = 5, force = true })
end)
check("headline clamps at the total", shown.dialog.headline_widget.text, "5 of 5 · 0 remaining")
check("bar reaches full", shown.dialog.progress_widget.percentage, 1)
local dialog = shown.dialog
shown:close()
check("dialog is closed", ui.shown[dialog], nil)
check("close is idempotent", (function() shown:close(); return true end)(), true)

print(failures == 0 and "\nALL PASS" or string.format("\n%d FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
