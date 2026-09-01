package.path = (os.getenv("PLUGIN_PATH") or "readwisereader.koplugin") .. "/?.lua;" .. package.path
local P = require("library/progress")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %-52s got=%s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-52s %s", name, tostring(got)))
    end
end

-- Reason returned when decide() declines, so a test asserts *why* it declined
-- rather than just that it did.
local function why(remote, state)
    local seed, reason = P.decide(remote, state)
    if seed then return "SEEDED" end
    return reason
end

local function percent(remote, state)
    local seed = P.decide(remote, state)
    return seed and seed.percent or nil
end

print("== ISO 8601 parsing ==")
check("Z is UTC", P.toEpoch("2026-08-30T00:00:00Z"), 1788048000)
check("no zone is treated as UTC", P.toEpoch("2026-08-30T00:00:00"), 1788048000)
check("+00:00 matches Z", P.toEpoch("2026-08-30T00:00:00+00:00"), 1788048000)
check("fractional seconds tolerated", P.toEpoch("2026-08-30T00:00:00.123456Z"), 1788048000)
check("positive offset shifts back", P.toEpoch("2026-08-30T02:00:00+02:00"), 1788048000)
check("negative offset shifts forward", P.toEpoch("2026-08-29T19:00:00-05:00"), 1788048000)
check("compact offset form", P.toEpoch("2026-08-30T02:00:00+0200"), 1788048000)
-- A winter date exercises the DST branch of the offset measurement.
check("winter date round-trips", P.toEpoch("2026-01-15T12:00:00Z"), 1768478400)
check("nil input", P.toEpoch(nil), nil)
check("empty string", P.toEpoch(""), nil)
check("garbage", P.toEpoch("not a date"), nil)
check("date only", P.toEpoch("2026-08-30"), nil)

print("\n== declines ==")
check("no reading_progress",
    why({ last_opened_at = "2026-08-30T00:00:00Z" }), "no remote progress")
check("null reading_progress",
    why({ reading_progress = nil, last_opened_at = "2026-08-30T00:00:00Z" }), "no remote progress")
check("barely opened",
    why({ reading_progress = 0.005, last_opened_at = "2026-08-30T00:00:00Z" }),
    "remote progress is negligible")
check("finished in Reader",
    why({ reading_progress = 1, last_opened_at = "2026-08-30T00:00:00Z" }),
    "remote document is finished")
check("never opened in Reader",
    why({ reading_progress = 0.4 }), "never opened in Reader")
check("last_opened_at is null",
    why({ reading_progress = 0.4, last_opened_at = nil }), "never opened in Reader")

print("\n== dead band ==")
local at_forty = { reading_progress = 0.40, last_opened_at = "2026-08-30T00:00:00Z" }
check("1% ahead is noise",
    why(at_forty, { local_percent = 0.39 }), "within the dead band")
check("exactly the dead band declines",
    why(at_forty, { local_percent = 0.38 }), "within the dead band")
check("beyond the dead band seeds",
    why(at_forty, { local_percent = 0.37 }), "SEEDED")
check("device already further ahead",
    why(at_forty, { local_percent = 0.80 }), "within the dead band")
check("no local percent yet seeds", why(at_forty, {}), "SEEDED")
check("seeded percent is the remote fraction", percent(at_forty, {}), 0.40)

print("\n== which side is fresher ==")
-- Reader opened 2026-08-30, device sidecar written 2026-08-29: Reader wins.
check("Reader newer than device",
    why(at_forty, { local_percent = 0.1, sidecar_mtime = P.toEpoch("2026-08-29T00:00:00Z") }),
    "SEEDED")
check("device newer than Reader",
    why(at_forty, { local_percent = 0.1, sidecar_mtime = P.toEpoch("2026-08-31T00:00:00Z") }),
    "device read more recently")
check("simultaneous is a device win",
    why(at_forty, { local_percent = 0.1, sidecar_mtime = P.toEpoch("2026-08-30T00:00:00Z") }),
    "device read more recently")

print("\n== a seed fires once ==")
check("unchanged last_opened_at does not re-seed",
    why(at_forty, { seen_last_opened_at = "2026-08-30T00:00:00Z" }), "no new Reader activity")
check("older last_opened_at does not re-seed",
    why(at_forty, { seen_last_opened_at = "2026-08-31T00:00:00Z" }), "no new Reader activity")
check("a later Reader session seeds again",
    why({ reading_progress = 0.6, last_opened_at = "2026-09-01T00:00:00Z" },
        { seen_last_opened_at = "2026-08-30T00:00:00Z", local_percent = 0.4 }), "SEEDED")
check("seed carries last_opened_at for the next comparison",
    (P.decide(at_forty, {}) or {}).last_opened_at, "2026-08-30T00:00:00Z")

print("\n== bad input is survivable ==")
check("nil remote", why(nil, {}), "no remote document")
check("non-table remote", why("nope", {}), "no remote document")
check("nil state still works", why(at_forty, nil), "SEEDED")
check("non-table state still works", why(at_forty, "nope"), "SEEDED")
check("string progress is coerced",
    why({ reading_progress = "0.4", last_opened_at = "2026-08-30T00:00:00Z" }, {}), "SEEDED")
check("string local_percent is coerced",
    why(at_forty, { local_percent = "0.39" }), "within the dead band")

print(failures == 0 and "\nALL PASS" or string.format("\n%d FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
