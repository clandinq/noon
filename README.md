<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/noon-lockup-dark.svg">
    <img alt="noon" src="assets/noon-lockup-light.svg" width="280">
  </picture>
</p>

<p align="center">A minimal window management app for macOS.</p>

## What it is

noon is a window management app that gives you three window shortcuts, modeled on [Moom](https://manytricks.com/moom/).
It is free, tiny, and needs nothing beyond [Hammerspoon](https://www.hammerspoon.org/).

| Shortcut | Action                          |
| -------- | ------------------------------- |
| ⌥⌘←      | Left half                       |
| ⌥⌘→      | Right half                      |
| ⌥⌘↑      | Fill the usable area            |

"Fill" means the screen's usable area (excluding the menu bar and Dock), like
Moom's fill. It is **not** macOS's green-button fullscreen or Spaces.

<!-- TODO: demo GIF -->

## Install

1. Install Hammerspoon:

   ```sh
   brew install --cask hammerspoon
   ```

2. Install the Spoon, either way:

   - **Release zip:** download `Noon.spoon.zip` from the
     [Releases page](https://github.com/clandinq/noon/releases), unzip it if needed, and
     double-click `Noon.spoon`. Hammerspoon installs it into `~/.hammerspoon/Spoons`.
   - **Git clone:**

     ```sh
     git clone https://github.com/clandinq/noon.git
     ln -s "$PWD/noon/Noon.spoon" ~/.hammerspoon/Spoons/Noon.spoon
     ```

3. Add these two lines to `~/.hammerspoon/init.lua`:

   ```lua
   hs.loadSpoon("Noon")
   spoon.Noon:start()
   ```

4. Reload the Hammerspoon config, then grant Hammerspoon **Accessibility** access
   (System Settings > Privacy & Security > Accessibility). It is required for the
   event tap and for moving windows.

## Configuration

The defaults are shown below. Call `bindHotkeys` before `start()` only if you want
different keys, for example Ctrl+Opt instead of Cmd+Opt:

```lua
hs.loadSpoon("Noon")
spoon.Noon:bindHotkeys({
  left  = {{"ctrl", "alt"}, "left"},
  right = {{"ctrl", "alt"}, "right"},
  fill  = {{"ctrl", "alt"}, "up"},
})
spoon.Noon:start()   -- spoon.Noon:stop() disables it
```

Defaults:

```lua
left  = {{"cmd", "alt"}, "left"}
right = {{"cmd", "alt"}, "right"}
fill  = {{"cmd", "alt"}, "up"}
```

Public fields:

- `spoon.Noon.tap`: the `hs.eventtap` object, useful for diagnosis.
- `spoon.Noon.logger`: an `hs.logger` named "Noon".

noon has no global side effects: it does not change the menu bar icon, the Dock icon,
autolaunch, or animation settings. Resizing is instant.

## How it works

noon uses an **event tap**. It intercepts the keystroke at a low level and consumes it,
so nothing else that listens for the same keys (the focused app, another window manager,
or macOS's own window tiling) ever receives it.

Normal global hotkeys (the Carbon API, `hs.hotkey`) are registered higher up and can lose
to shortcuts handled at a lower level. With some macOS versions and settings, built-in
window tiling has acted on Cmd+Opt+Up first, so a hotkey-based tool produced "top half"
instead of "fill". An event tap runs before any of these, so it always wins.

A few details keep it reliable:

- **The callback does almost nothing.** macOS disables an event tap whose callback runs
  too long, so the callback only defers the resize to a timer and returns immediately.
- **A 2-second watchdog rebuilds the tap.** If macOS disables the tap, the watchdog
  stops it and creates a fresh `hs.eventtap.new(...)`. Calling `:start()` on a disabled
  tap does not reliably revive it. The watchdog also logs a warning to the Hammerspoon
  console when Secure Input is on (see below).
- **The usable area is double-checked against the Dock.** A long-running process can
  see a stale `screen:frame()` that ignores the Dock, so noon compares it with the
  Dock's live Accessibility frame before tiling.

## Troubleshooting

**Shortcuts silently stop working everywhere.** Most likely Secure Input is on: some app
(usually a focused password field) has asked macOS to hide keystrokes from event taps.
Check it, and find the process holding it:

```sh
hs -c 'return hs.eventtap.isSecureInputEnabled()'
ioreg -l -w 0 | grep -o 'kCGSSessionSecureInputPID"=[0-9]*'
ps -p <pid>
```

(`hs` needs `require("hs.ipc")` in your config; see [Optional tips](#optional-tips).)
Leave the password field or quit that app. Restarting Hammerspoon does not help.

**Chrome tab switching stopped working.** Chrome and some other apps use Cmd+Opt+Left/Right
to switch tabs, and noon consumes those keys globally. Use Ctrl+Tab / Ctrl+Shift+Tab
instead, or remap noon with `bindHotkeys`.

**Debug logging.** Show every key noon consumes in the Hammerspoon console:

```lua
spoon.Noon.logger.setLogLevel("debug")
```

**Check the tap from the shell.** With `require("hs.ipc")` loaded:

```sh
hs -c 'return spoon.Noon.tap:isEnabled()'
```

**Nothing happens at all.** Confirm Hammerspoon is listed and enabled under System
Settings > Privacy & Security > Accessibility, then reload the config.

## Optional tips

Put these in `~/.hammerspoon/init.lua`. noon deliberately does not set them for you.

```lua
hs.menuIcon(false)      -- hide the menu bar icon
hs.dockIcon(false)      -- hide the Dock icon
hs.autoLaunch(true)     -- launch Hammerspoon at login
require("hs.ipc")       -- enable the `hs` command-line tool for live queries
```

With the menu icon hidden, reload the config from the shell: `hs -c 'hs.reload()'`.

## Uninstall

Remove the two lines (`hs.loadSpoon("Noon")` and `spoon.Noon:start()`) from
`~/.hammerspoon/init.lua`, then delete the Spoon:

```sh
rm -rf ~/.hammerspoon/Spoons/Noon.spoon
```

To remove Hammerspoon entirely: `brew uninstall --cask hammerspoon`.

## License

[MIT](LICENSE). noon is not affiliated with Many Tricks or Moom.
