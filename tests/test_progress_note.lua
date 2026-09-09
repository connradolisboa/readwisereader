package.path = (os.getenv("PLUGIN_PATH") or "readwisereader.koplugin") .. "/?.lua;" .. package.path
local Note = require("library/progress_note")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %-46s got=%s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-46s %s", name, tostring(got)))
    end
end

print("== managed Reader progress note ==")
check("rounds a local fraction", Note.format(0.426), "KOReader progress: 43% <!-- koreader-progress -->")
check("zero is valid", Note.format(0), "KOReader progress: 0% <!-- koreader-progress -->")
check("rejects a fraction over one", Note.format(1.1), nil)

local existing = "My own note\nSecond paragraph"
local added, added_changed = Note.upsert(existing, 0.42)
check("append preserves existing note", added,
    existing .. "\nKOReader progress: 42% <!-- koreader-progress -->")
check("append reports a change", added_changed, true)

local replaced, replaced_changed = Note.upsert(added, 0.67)
check("replace keeps own note text", replaced,
    existing .. "\nKOReader progress: 67% <!-- koreader-progress -->")
check("replace reports a change", replaced_changed, true)
check("same percentage does not rewrite note", select(2, Note.upsert(replaced, 0.67)), false)

local removed, removed_changed = Note.remove(replaced)
check("remove preserves all non-plugin text", removed, existing .. "\n")
check("remove reports a managed line", removed_changed, true)
check("remove does nothing without the marker", (Note.remove(existing)), existing)
check("remove reports no marker", select(2, Note.remove(existing)), false)

print(failures == 0 and "\nALL PASS" or string.format("\n%d FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
