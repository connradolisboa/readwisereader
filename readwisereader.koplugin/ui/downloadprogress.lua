-- Cancelable download progress dialog.
--
-- KOReader gained a stock ProgressbarDialog in mid-2025, but its texts are
-- fixed at construction and it cancels by tapping anywhere rather than with a
-- button. This builds the same thing from widgets that have been in KOReader
-- since 2013 so it works on older Kindle builds, keeps every line mutable, and
-- offers a real Cancel button.
--
-- A blocking download loop never gives UIManager the chance to process a tap,
-- so cancellation uses the coroutine handshake the OTA updater uses: each
-- update schedules a resume on the next tick and yields, and the Cancel button
-- resumes early with the cancelled flag set. The caller must therefore run
-- inside Trapper:wrap(); without a coroutine the dialog still displays but
-- cannot be cancelled.
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local socket = require("socket")
local util = require("util")
local Screen = Device.screen

-- Full e-ink repaints are expensive, so redraw at most this often while work is
-- running. It also bounds how quickly a Cancel tap is noticed, because the tap
-- can only be processed at one of these points.
local REDRAW_INTERVAL = Device:hasEinkScreen() and 0.5 or 0.1

local Dialog = InputContainer:extend{
    title = nil,
    width = nil,
    cancel_callback = nil,
}

function Dialog:init()
    self.align = "center"
    self.dimen = Screen:getSize()

    local content_width = self.width or math.floor(Screen:getWidth() * 0.8)

    self.headline_widget = TextWidget:new{
        text = "",
        face = Font:getFace("cfont", 18),
        bold = true,
        max_width = content_width,
    }
    self.item_widget = TextWidget:new{
        text = "",
        face = Font:getFace("cfont", 16),
        max_width = content_width,
    }
    self.detail_widget = TextWidget:new{
        text = "",
        face = Font:getFace("cfont", 15),
        max_width = content_width,
    }
    self.progress_widget = ProgressWidget:new{
        width = content_width,
        height = Screen:scaleBySize(16),
        percentage = 0,
        fillcolor = Blitbuffer.COLOR_BLACK,
        margin_v = Size.margin.small,
    }
    self.cancel_button = Button:new{
        text = "Cancel",
        width = math.floor(content_width / 2),
        show_parent = self,
        callback = function()
            if self.cancel_callback then
                self.cancel_callback()
            end
        end,
    }

    local group = VerticalGroup:new{
        align = "center",
        TextWidget:new{
            text = self.title or "",
            face = Font:getFace("cfont", 20),
            bold = true,
            max_width = content_width,
        },
        VerticalSpan:new{ width = Size.padding.large },
        self.headline_widget,
        VerticalSpan:new{ width = Size.padding.small },
        self.progress_widget,
        VerticalSpan:new{ width = Size.padding.small },
        self.item_widget,
        self.detail_widget,
        VerticalSpan:new{ width = Size.padding.large },
        CenterContainer:new{
            dimen = Geom:new{ w = content_width, h = self.cancel_button:getSize().h },
            self.cancel_button,
        },
    }

    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        FrameContainer:new{
            radius = Size.radius.window,
            bordersize = Size.border.window,
            padding = Size.padding.large,
            background = Blitbuffer.COLOR_WHITE,
            group,
        },
    }
end

local Progress = {}
Progress.__index = Progress

-- Creates and shows the dialog. Returns nil when the widgets cannot be built,
-- so a caller can degrade to a plain message instead of failing a sync.
function Progress.start(options)
    options = options or {}

    local self = setmetatable({
        total = tonumber(options.total) or 0,
        done = 0,
        bytes = 0,
        cancelled = false,
        waiting = false,
        last_redraw = 0,
        co = coroutine.running(),
    }, Progress)

    local ok, dialog = pcall(function()
        return Dialog:new{
            title = options.title or "Downloading",
            cancel_callback = function() self:_onCancel() end,
        }
    end)
    if not ok or not dialog then
        logger.warn("ReadwiseReader: progress dialog unavailable, falling back to messages", dialog)
        return nil
    end

    self.dialog = dialog
    if not self.co then
        -- Without a coroutine there is nowhere to yield, so the button can
        -- never fire. Say so rather than showing a control that does nothing.
        logger.warn("ReadwiseReader: progress dialog not wrapped in a coroutine, cancel disabled")
        self.dialog.cancel_button:disable()
    end

    UIManager:show(self.dialog)
    UIManager:forceRePaint()
    return self
end

function Progress:_onCancel()
    if self.cancelled then
        return
    end
    self.cancelled = true
    self.dialog.headline_widget:setText("Cancelling…")
    self.dialog.cancel_button:disable()
    self:_repaint()
    -- Resume the worker immediately so it stops at its next check rather than
    -- after the current redraw interval.
    if self.waiting then
        self.waiting = false
        coroutine.resume(self.co)
    end
end

function Progress:_repaint()
    UIManager:setDirty(self.dialog, function()
        return "ui", self.dialog.dimen
    end)
    UIManager:forceRePaint()
end

-- Hands control back to UIManager just long enough for a queued Cancel tap to
-- be dispatched, then continues. This is the only point at which the button can
-- take effect.
function Progress:_pump()
    if self.cancelled or not self.co then
        return
    end
    self.waiting = true
    UIManager:nextTick(function()
        if self.waiting then
            self.waiting = false
            coroutine.resume(self.co)
        end
    end)
    coroutine.yield()
end

-- Redraws the dialog from current state if the throttle interval has elapsed.
function Progress:_refresh(force)
    local now = socket.gettime()
    if not force and (now - self.last_redraw) < REDRAW_INTERVAL then
        return false
    end
    self.last_redraw = now

    local remaining = math.max(self.total - self.done, 0)
    self.dialog.headline_widget:setText(string.format(
        "%d of %d · %d remaining", math.min(self.done + 1, self.total), self.total, remaining))
    self.dialog.item_widget:setText(self.item or "")
    self.dialog.detail_widget:setText(string.format(
        "%s downloaded", util.getFriendlySize(self.bytes) or "0 B"))
    if self.total > 0 then
        self.dialog.progress_widget:setPercentage(self.done / self.total)
    end

    self:_repaint()
    return true
end

function Progress:_apply(fields)
    if fields.done then self.done = fields.done end
    if fields.bytes then self.bytes = fields.bytes end
    if fields.item then self.item = fields.item end
end

--- Redraws and gives the Cancel button a chance to fire. Returns true when the
--- user has cancelled.
---
--- MUST NOT be called from inside a string.gsub callback: LuaJIT cannot yield
--- across a C-call boundary, so the yield would raise. Use tick() there.
---
--- fields.done   completed item count
--- fields.item   label for what is being worked on now
--- fields.bytes  cumulative bytes written so far
--- fields.force  redraw now instead of waiting for the throttle interval
function Progress:update(fields)
    if self.cancelled then
        return true
    end
    fields = fields or {}
    self:_apply(fields)
    if self:_refresh(fields.force) then
        self:_pump()
    end
    return self.cancelled
end

--- Redraw-only variant that never yields, so it is safe inside a gsub callback.
--- The Cancel button cannot fire here; it takes effect at the next update().
function Progress:tick(fields)
    if self.cancelled then
        return true
    end
    self:_apply(fields or {})
    self:_refresh(false)
    return self.cancelled
end

--- Reports bytes fetched inside the current item, so a large article with many
--- images does not look frozen. Called from image fetching, which runs inside a
--- gsub callback, so this only redraws.
function Progress:addBytes(count)
    if self.cancelled then
        return true
    end
    return self:tick({ bytes = self.bytes + (tonumber(count) or 0) })
end

function Progress:isCancelled()
    return self.cancelled
end

function Progress:close()
    if self.dialog then
        UIManager:close(self.dialog)
        self.dialog = nil
    end
end

return Progress
