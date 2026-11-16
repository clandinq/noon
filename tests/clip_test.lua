-- Tests for Noon.clipToDock. Runs inside Hammerspoon (no standalone Lua needed):
--   hs -c "dofile('/abs/path/to/tests/clip_test.lua')"
-- Loads the Spoon file directly; it does not start the tap.
--
-- Geometry: a generic 1440x900 screen with a 25px menu bar, so the usable
-- area is y = 25..900 when the Dock is (wrongly) ignored.

local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")
local noon = dofile(here .. "/../Noon.spoon/init.lua")

assert(noon.tap == nil and noon.watchdog == nil, "loading the Spoon must not start anything")

local count = 0
local function check(name, got, want)
  count = count + 1
  for _, k in ipairs({ "x", "y", "w", "h" }) do
    assert(got[k] == want[k],
      string.format("%s: %s expected %s, got %s", name, k, tostring(want[k]), tostring(got[k])))
  end
end

local stale = { x = 0, y = 25, w = 1440, h = 875 }

-- (a) stale frame ignores a bottom Dock: clipped so the bottom edge is the Dock top
local r = noon.clipToDock(stale, { x = 100, y = 830, w = 1240, h = 60 })
check("bottom dock, stale frame", r, { x = 0, y = 25, w = 1440, h = 805 })
assert(r.y + r.h == 830, "bottom edge should sit on the Dock top")

-- (b) correct frame already ends above the Dock center: unchanged
check("bottom dock, correct frame", noon.clipToDock({ x = 0, y = 25, w = 1440, h = 810 },
  { x = 100, y = 830, w = 1240, h = 60 }), { x = 0, y = 25, w = 1440, h = 810 })

-- (c) left Dock
check("left dock", noon.clipToDock(stale, { x = 0, y = 150, w = 60, h = 600 }),
  { x = 60, y = 25, w = 1380, h = 875 })

-- (d) right Dock
check("right dock", noon.clipToDock(stale, { x = 1380, y = 150, w = 60, h = 600 }),
  { x = 0, y = 25, w = 1380, h = 875 })

-- (e) auto-hidden Dock sits off-screen: unchanged
check("hidden dock", noon.clipToDock(stale, { x = 100, y = 905, w = 1240, h = 60 }), stale)

-- inputs are never mutated, and the result is a new table
local frame = { x = 0, y = 25, w = 1440, h = 875 }
local dock = { x = 100, y = 830, w = 1240, h = 60 }
local out = noon.clipToDock(frame, dock)
check("frame not mutated", frame, { x = 0, y = 25, w = 1440, h = 875 })
check("dock not mutated", dock, { x = 100, y = 830, w = 1240, h = 60 })
assert(out ~= frame, "result must be a new table")
count = count + 1

local msg = string.format("clip_test: all %d tests passed", count)
print(msg)
return msg
