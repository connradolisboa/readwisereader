-- Managed, visible Reader-document note line for one local KOReader percentage.
-- The unique HTML marker lets us replace or remove only our own line while
-- preserving every other part of the user's Reader note.
local ProgressNote = {}

local MARKER = "<!-- koreader-progress -->"

local function normalizeNotes(notes)
    return type(notes) == "string" and notes or ""
end

local function normalizedPercent(percent)
    percent = tonumber(percent)
    if not percent or percent < 0 or percent > 1 then
        return nil
    end
    return percent
end

function ProgressNote.format(percent)
    percent = normalizedPercent(percent)
    if not percent then
        return nil
    end
    return string.format("KOReader progress: %d%% %s", math.floor(percent * 100 + 0.5), MARKER)
end

function ProgressNote.remove(notes)
    notes = normalizeNotes(notes)
    -- The marker is generated only by this plugin. Remove its entire line and
    -- one adjacent newline so a remove action does not leave a blank paragraph.
    local updated, removed = notes:gsub("[^\r\n]*<!%-%- koreader%-progress %-%->[^\r\n]*[\r]?\n?", "")
    return updated, removed > 0
end

function ProgressNote.upsert(notes, percent)
    local line = ProgressNote.format(percent)
    if not line then
        return nil, false
    end
    local base, removed = ProgressNote.remove(notes)
    if base == "" then
        return line, true
    end
    local separator = base:match("[\r\n]$") and "" or "\n"
    local updated = base .. separator .. line
    return updated, updated ~= normalizeNotes(notes)
end

ProgressNote.MARKER = MARKER

return ProgressNote
