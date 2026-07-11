---
name: verifier-settings
description: Build, launch, and DRIVE the Claude Code Buddy macOS settings window — open it, switch panels (general/about/hotkey/plugins/snip), and capture screenshots + frame geometry as verification evidence. Use when verifying changes to the settings/plugins/snip UI, the NSSplitView layout, or any settings-window-sizing change. Bypasses the LSUIElement osascript-click-doesn't-route limitation via the `buddy launcher debug` CLI.
---

# verifier-settings — drive the settings window

This skill verifies changes to the **desktop app's settings window** (settings sections, plugins gallery, snip panel, NSSplitView layout, window sizing). The app is an **LSUIElement accessory app** — `osascript` click / `AXPress` / keystroke do **not** route to its windows (`patterns/2026-06-23`). The only reliable automation path is the **`buddy launcher debug` CLI**, which talks to the running app over its Unix socket and drives the settings window in-process.

The harness is `driver.sh` in this directory. **Run that; don't improvise GUI automation.**

Paths below are relative to repo root (`claude-code-buddy/`). The driver lives at `.claude/skills/verifier-settings/driver.sh`.

## Prerequisites

- macOS (this is a native Swift/AppKit app — it cannot run on Linux).
- Xcode + Swift toolchain, SwiftLint (`brew install swiftlint`).
- The app must be **bundled** so the in-bundle `buddy` CLI (with the `debug open-settings` / `select-section` / `select-plugin` / `get-state` subcommands) exists. The Homebrew-installed `/opt/homebrew/bin/buddy` is an older build without these.

## Build + launch (one-time per session)

```bash
SKIP_FETCH_PLUGINS=1 make -C apps/desktop bundle
pkill -f ClaudeCodeBuddy; sleep 1
open apps/desktop/ClaudeCodeBuddy.app
sleep 3
```

`SKIP_FETCH_PLUGINS=1` skips the plugin fetch (faster; fine when bundled plugins already exist).

## Drive the window (agent path — use driver.sh)

The in-bundle CLI is at `apps/desktop/ClaudeCodeBuddy.app/Contents/MacOS/buddy`. The driver wraps it.

**Full sweep (build → launch → screenshot every panel → cleanup):**

```bash
.claude/skills/verifier-settings/driver.sh all
```

**Or step-by-step:**

```bash
BUDDY=apps/desktop/ClaudeCodeBuddy.app/Contents/MacOS/buddy

# Open the settings window (optionally preselect a section). This is the unblocker:
$BUDDY launcher debug open-settings general

# Switch main section: general | about | hotkey | skins | plugins
$BUDDY launcher debug select-section about

# In the plugins section, select a plugin panel (e.g. snip):
$BUDDY launcher debug select-section plugins
$BUDDY launcher debug select-plugin snip

# Dump window geometry + selection (JSON — for frame predicates):
$BUDDY launcher debug get-state

# Screenshot:
screencapture -x /tmp/verifier-settings-evidence/<name>.png

# Drive + capture one panel via the driver:
.claude/skills/verifier-settings/driver.sh drive snip

# Cleanup:
pkill -f ClaudeCodeBuddy
```

Screenshots + `get-state` JSON land in `/tmp/verifier-settings-evidence/` (override with `VERIFIER_EVIDENCE_DIR=...`).

## What `get-state` returns (frame predicates)

```json
{
  "data": {
    "window_open": true,
    "window": { "x":.., "y":.., "width":.., "height":.., "isKeyWindow":true, "title":"设置" },
    "selectedSection": "plugins",          // general|about|hotkey|skins|plugins
    "sidebarWidth": 200,                    // expect 200 (SettingsTheme.sidebarWidth)
    "detailVC": "PluginGalleryViewController",
    "detailAX": "settings.detail",
    "pluginListWidth": 240,                 // plugins section only; expect 240
    "contentColumnWidth": 0,                // ⚠️ known-imperfect metric, see Gotchas
    "selectedPlugin": "snip"                // plugins section only
  }
}
```

Assert against: `sidebarWidth == 200`, `pluginListWidth == 240`, `window.width >= 800` (minSize), `isKeyWindow == true`. For content-column width, rely on **window width via osascript** (`≤ ~980 ⇒ content ≤ 780`) + visual screenshot — the in-process `contentColumnWidth` read is unreliable (see Gotchas).

## Run (human path)

```bash
open apps/desktop/ClaudeCodeBuddy.app        # cat appears in menu bar
# Click the menu-bar cat → 设置 (osascript can't do this click reliably)
```

Useless for headless/automated verification — that's why this skill exists.

## Gotchas

- **LSUIElement = no osascript routing.** `osascript -e 'tell process "ClaudeCodeBuddy" to AXPress status item'` returns success but the settings window does **not** open. `osascript` keystroke/click likewise no-ops. Only the `buddy launcher debug` CLI (in-process socket) opens/switches the window. AX **read** (window frame) is reliable and can cross-check `get-state`.
- **Use the in-bundle `buddy`, not the Homebrew one.** `/opt/homebrew/bin/buddy` is an older release without the `debug open-settings` family. Always invoke `apps/desktop/ClaudeCodeBuddy.app/Contents/MacOS/buddy` after a fresh `make bundle`.
- **Window sizing: NSSplitViewController shrinks-to-fittingSize on section switch.** This was a real defect (window collapsed to 449×48 / 208×40, below its own minSize). Fixed by flooring the splitView `fittingSize` via a `≥ minSize` constraint in `SettingsSplitViewController.viewDidLoad` (search the file for "fittingSize 下限"). After the fix the window holds at **800×572 (the minSize floor)** after a section switch — usable but not the full 1440×788 initial size. The first `open-settings` opens larger; `select-section` settles to the floor. If you see a sub-minSize window again, that floor constraint regressed.
- **`contentColumnWidth` in `get-state` reads 0.** It's an in-process bounds read over the socket that lands between layout passes; the panel **does** render (confirm via screenshot). Don't use it as a hard predicate; use window width + visual instead.
- **Window loses key focus during `screencapture`.** `get-state` may show `isKeyWindow: false` right after a screenshot — re-run `open-settings` if you need it key.
- **`make build` ≠ `make bundle`.** `make build` compiles to `.build/debug/`; `open ClaudeCodeBuddy.app` runs the **bundled** app. Always `make bundle` so the running app + in-bundle CLI reflect your changes.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `buddy launcher debug open-settings` → `Buddy app is not running` | `open apps/desktop/ClaudeCodeBuddy.app; sleep 3` (wait for socket) |
| `open-settings` reports ok but window invisible / sub-minSize | The splitView `fittingSize` floor constraint regressed — re-check `SettingsSplitViewController.viewDidLoad`. |
| `select-plugin snip` → `plugin not found or gallery not loaded` | Gallery starts `.loading` and refreshes async; the handler awaits `refresh()` before selecting. Retry once; if persistent, check `PluginPanelRegistry` registers `"snip"` (`PluginGalleryViewController.init`). |
| App vanishes mid-drive | A prior `viewDidLayout`/`setFrame` "fight the shrink" fix recursed and crashed the app. The current fix (fittingSize floor) does **not** recurse — if a crash returns, that approach was reintroduced. |
| `make bundle` fails on fetch | `SKIP_FETCH_PLUGINS=1 make -C apps/desktop bundle` |

## Scope notes

This skill drives the **settings window only** (sections + plugins + snip). For cat-scene / session-state verification use `buddy inspect` / `buddy click` (see `apps/desktop/CLAUDE.md` QA section). For full manual E2E there is a separate `buddy-e2e-test` skill.
