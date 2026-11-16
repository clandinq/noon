--- === Noon ===
---
--- Minimal window tiling: left half, right half, fill the usable screen area.
---
--- Why an event tap instead of hs.hotkey: normal hotkey APIs can lose to
--- shortcuts handled at a lower level (with some macOS versions and settings,
--- built-in window tiling has acted on Cmd+Opt+Up first). An event tap sees the
--- keystroke before anything else and consumes it, so no other handler fires.
---
--- Robustness: macOS disables an event tap whose callback runs too long, and it
--- stays disabled. So the callback is kept trivial (the resize is deferred), the
--- resize is instant (no animation), and a watchdog rebuilds the tap if the
--- system ever disables it.
---
--- Download: https://github.com/clandinq/noon

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "Noon"
obj.version = "0.1.0"
obj.author = "clandinq"
obj.homepage = "https://github.com/clandinq/noon"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- Noon.logger
--- Variable
--- hs.logger instance (id "Noon"). Per-key and "no focused window" messages are
--- debug level; tap rebuilds, stale-frame clips and Secure Input are warnings.
--- Raise verbosity with `spoon.Noon.logger.setLogLevel("debug")`.
obj.logger = hs.logger.new("Noon")

--- Noon.tap
--- Variable
--- The hs.eventtap that consumes the shortcuts, or nil while stopped. Exposed so
--- a running instance can be diagnosed live, e.g. from the command line:
--- `hs -c 'return spoon.Noon.tap:isEnabled()'` (needs `require("hs.ipc")`).
obj.tap = nil

--- Noon.watchdog
--- Variable
--- The hs.timer that checks the tap (and Secure Input) every 2 seconds, or nil
--- while stopped.
obj.watchdog = nil

-- Default shortcuts, used for any action not overridden in bindHotkeys().
local DEFAULT_MAPPING = {
  left  = { { "cmd", "alt" }, "left" },
  right = { { "cmd", "alt" }, "right" },
  fill  = { { "cmd", "alt" }, "up" },
}

-- Modifier aliases accepted in a mapping, normalized to the flag names that
-- hs.eventtap.event:getFlags() reports.
local MOD_ALIASES = {
  cmd = "cmd", command = "cmd",
  alt = "alt", option = "alt",
  ctrl = "ctrl", control = "ctrl",
  shift = "shift",
}
local MOD_NAMES = { "cmd", "alt", "ctrl", "shift" }

-- keycode -> list of { action = <string>, mods = { cmd = true, ... } }.
-- Filled by bindHotkeys(); read by the tap callback, so rebinding takes effect
-- immediately even while the tap is running.
local bindings = {}

--- Noon.clipToDock(frame, dock)
--- Function
--- Clips a usable-area rectangle so it does not overlap the Dock.
---
--- Parameters:
---  * frame - a table {x=, y=, w=, h=} (top-left origin, like Hammerspoon) with
---    the area believed to exclude the Dock
---  * dock - a table {x=, y=, w=, h=} with the Dock's live on-screen frame
---
--- Returns:
---  * A new table {x=, y=, w=, h=}; the inputs are not modified.
---
--- Notes:
---  * Clips only if the Dock's center point lies inside `frame` (edges count as
---    inside). That means `frame` ignored the Dock. Otherwise `frame` is returned
---    unchanged and trusted as-is: it is pixel-exact, whereas the Dock's
---    Accessibility frame includes some padding that macOS lets windows cover. An
---    auto-hidden Dock sits off-screen, so its center is never inside the frame.
---  * Dock position is inferred from its shape and location: wider than tall
---    means bottom; otherwise left or right depending on which half of `frame`
---    its center is in.
function obj.clipToDock(frame, dock)
  local m = { x = frame.x, y = frame.y, w = frame.w, h = frame.h }
  local cx = dock.x + dock.w / 2
  local cy = dock.y + dock.h / 2
  local inside = cx >= frame.x and cx <= frame.x + frame.w
    and cy >= frame.y and cy <= frame.y + frame.h
  if not inside then return m end

  if dock.w >= dock.h then                         -- Dock at the bottom
    m.h = math.min(m.h, dock.y - m.y)
  elseif cx < frame.x + frame.w / 2 then           -- Dock on the left
    local right = m.x + m.w
    m.x = math.max(m.x, dock.x + dock.w)
    m.w = right - m.x
  else                                             -- Dock on the right
    m.w = math.min(m.w, dock.x - m.x)
  end
  return m
end

-- Usable area of a screen. screen:frame() is supposed to exclude the menu bar
-- and Dock, but in a very long-running Hammerspoon process it can go stale and
-- stop excluding the Dock (windows then tile underneath it). So check it against
-- the Dock's live on-screen frame, read via Accessibility, and clip if needed.
local function usableFrame(screen)
  local f = screen:frame()
  local m = { x = f.x, y = f.y, w = f.w, h = f.h }
  local dockApp = hs.application.find("com.apple.dock")
  if not dockApp then return m end
  for _, el in ipairs(hs.axuielement.applicationElement(dockApp):attributeValue("AXChildren") or {}) do
    if el:attributeValue("AXRole") == "AXList" then
      local p, s = el:attributeValue("AXPosition"), el:attributeValue("AXSize")
      if p and s then
        local clipped = obj.clipToDock(m, { x = p.x, y = p.y, w = s.w, h = s.h })
        if clipped.x ~= m.x or clipped.w ~= m.w or clipped.h ~= m.h then
          obj.logger.w("screen frame is stale (ignores the Dock), clipping to Dock edge")
        end
        m = clipped
      end
    end
  end
  return m
end

-- Tile the focused window. action is "left", "right" or "fill".
local function place(action)
  local win = hs.window.focusedWindow()
  if not win then
    obj.logger.d("no focused window")
    return
  end
  local m = usableFrame(win:screen())  -- usable area: excludes menu bar and Dock
  local rect
  if action == "left" then
    rect = { x = m.x, y = m.y, w = m.w / 2, h = m.h }
  elseif action == "right" then
    rect = { x = m.x + m.w / 2, y = m.y, w = m.w / 2, h = m.h }
  else -- fill
    rect = m
  end
  win:setFrame(rect, 0)  -- 0 = no animation, without touching the global setting
end

-- Event tap callback. Returns true to consume the keystroke.
local function handleKeyDown(e)
  local entries = bindings[e:getKeyCode()]
  if not entries then return false end
  local flags = e:getFlags()
  for _, entry in ipairs(entries) do
    -- Require exactly the configured modifiers among cmd/alt/ctrl/shift. The fn
    -- flag is ignored: macOS sets it automatically on arrow keys.
    local match = true
    for _, name in ipairs(MOD_NAMES) do
      if (flags[name] == true) ~= (entry.mods[name] == true) then
        match = false
        break
      end
    end
    if match then
      -- Defer the actual resize so this callback returns immediately and macOS
      -- never disables the tap for being slow.
      obj.logger.d("key fired: " .. entry.action)
      hs.timer.doAfter(0, function() place(entry.action) end)
      return true  -- consume so the system shortcut does not also fire
    end
  end
  return false
end

-- Build (or rebuild) the tap from scratch. Just calling tap:start() on an
-- already-disabled tap doesn't reliably bring it back on every macOS version, so
-- the watchdog recreates the underlying CGEventTapRef instead.
local function buildTap()
  if obj.tap then obj.tap:stop() end
  obj.tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, handleKeyDown)
  obj.tap:start()
end

-- Last observed Secure Input state, to log only on transitions.
local secureInput = false

--- Noon:init()
--- Method
--- Called by hs.loadSpoon(). Installs the default shortcuts; has no other
--- effects (it does not start the tap).
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Noon object
function obj:init()
  return self:bindHotkeys(DEFAULT_MAPPING)
end

--- Noon:bindHotkeys(mapping)
--- Method
--- Binds the tiling shortcuts. Actions missing from `mapping` keep their default.
--- Can be called before or after :start().
---
--- Parameters:
---  * mapping - an optional table with any of the keys `left`, `right`, `fill`,
---    each a pair `{ {modifiers}, "key" }`. Defaults:
---    * left  = {{"cmd", "alt"}, "left"}
---    * right = {{"cmd", "alt"}, "right"}
---    * fill  = {{"cmd", "alt"}, "up"}
---
--- Returns:
---  * The Noon object
---
--- Notes:
---  * Modifiers are any of cmd, alt, ctrl, shift (also command, option, control).
---    A shortcut fires only when exactly those modifiers are held.
---  * Raises an error for an unknown action, key name or modifier.
function obj:bindHotkeys(mapping)
  local spec = {}
  for action, def in pairs(DEFAULT_MAPPING) do spec[action] = def end
  for action, def in pairs(mapping or {}) do
    if not DEFAULT_MAPPING[action] then
      error("Noon: unknown action '" .. tostring(action) .. "' (expected left, right or fill)", 2)
    end
    spec[action] = def
  end

  local new = {}
  for action, def in pairs(spec) do
    local modList, key = def[1], def[2]
    local code = hs.keycodes.map[key]
    if type(modList) ~= "table" or type(key) ~= "string" or not code then
      error("Noon: invalid shortcut for '" .. action .. "' (expected {{modifiers}, \"key\"}, got key "
        .. tostring(key) .. ")", 2)
    end
    local mods = {}
    for _, name in ipairs(modList) do
      local flag = MOD_ALIASES[string.lower(tostring(name))]
      if not flag then
        error("Noon: unknown modifier '" .. tostring(name) .. "' for '" .. action
          .. "' (expected cmd, alt, ctrl or shift)", 2)
      end
      mods[flag] = true
    end
    new[code] = new[code] or {}
    table.insert(new[code], { action = action, mods = mods })
  end
  bindings = new
  return self
end

--- Noon:start()
--- Method
--- Starts the event tap and its watchdog. Calling it again while running does
--- nothing.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Noon object
---
--- Notes:
---  * Hammerspoon needs Accessibility permission for the tap and for moving
---    windows. The watchdog rebuilds the tap if macOS disables it, and warns
---    (once per occurrence) while Secure Input is on, since macOS then stops
---    delivering keystrokes to event taps.
function obj:start()
  if self.watchdog then return self end
  if next(bindings) == nil then self:bindHotkeys() end
  buildTap()
  self.watchdog = hs.timer.doEvery(2, function()
    if not self.tap or not self.tap:isEnabled() then
      self.logger.w("tap was disabled, rebuilding")
      buildTap()
    end
    local secure = hs.eventtap.isSecureInputEnabled()
    if secure and not secureInput then
      self.logger.w("Secure Input is on (another app, often a password field, holds it); shortcuts are paused until it is released")
    elseif secureInput and not secure then
      self.logger.i("Secure Input is off; shortcuts resumed")
    end
    secureInput = secure
  end)
  return self
end

--- Noon:stop()
--- Method
--- Stops the event tap and watchdog. The shortcuts stop being consumed.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Noon object
function obj:stop()
  if self.watchdog then
    self.watchdog:stop()
    self.watchdog = nil
  end
  if self.tap then
    self.tap:stop()
    self.tap = nil
  end
  secureInput = false
  return self
end

return obj
