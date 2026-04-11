# Session Identity & Cat-Terminal Mapping — Design Spec

> **Date**: 2026-04-11
> **Status**: Approved
> **Approach**: Hybrid (Smart Overlay + Menu Bar Dashboard)

## Problem

When 6–7 Claude Code sessions run simultaneously, the user sees 6–7 cats on the Dock but cannot tell which cat corresponds to which terminal window. There is no visual distinction between cats and no way to navigate from a cat to its terminal.

## Solution Overview

Five capabilities, delivered in phases:

1. **Permanent labels** above each cat (auto-generated from cwd, overridable by AI via CLI)
2. **Color coding** with bi-directional matching (cat tint + terminal statusline)
3. **Hover tooltip** showing session details on mouse-over
4. **Click-to-activate** bringing the exact Ghostty tab to the foreground
5. **Menu bar dashboard** as a supplementary session list when cats are occluded

## 1. Data Model & Protocol Extension

### 1.1 Extended HookMessage

Add optional `cwd` field to the existing message schema. The hook script extracts `cwd` from Claude Code's stdin JSON on the first message for each session.

```json
{"session_id":"uuid","event":"thinking","tool":null,"timestamp":123,"cwd":"/Users/.../my-project"}
```

Swift changes to `HookMessage.swift`:
- Add `cwd: String?` (optional, `CodingKeys` maps to `"cwd"`)
- Add `label: String?` (optional, for `set_label` events)

### 1.2 New HookEvent: `.setLabel`

```json
{"session_id":"uuid","event":"set_label","label":"重构登录","timestamp":123}
```

Add `case setLabel = "set_label"` to `HookEvent`. The `catState` computed property returns `nil` for `.setLabel` (no state change, label update only).

### 1.3 SessionInfo Model

New file: `Sources/ClaudeCodeBuddy/Session/SessionInfo.swift`

```swift
struct SessionInfo {
    let sessionId: String
    var label: String          // display name (default = last path component of cwd)
    var color: SessionColor    // assigned color
    var cwd: String?           // working directory
    var pid: Int?              // process ID (from ~/.claude/sessions/)
    var state: CatState        // current state
    var lastActivity: Date
}
```

### 1.4 SessionColor

New file: `Sources/ClaudeCodeBuddy/Session/SessionColor.swift`

```swift
enum SessionColor: Int, CaseIterable {
    case coral, teal, gold, violet, mint, peach, sky, rose

    var hex: String { ... }       // e.g. "#FF6B6B"
    var nsColor: NSColor { ... }  // for SpriteKit tinting
    var ansi256: Int { ... }      // for terminal statusline
}
```

8 colors, matching the max-8-cats limit. Colors are assigned in order on session creation and recycled when sessions end.

## 2. Session Metadata Enrichment

### 2.1 Primary Path: Hook Script

`buddy-hook.sh` extracts `cwd` from the Claude Code stdin JSON. If not available in stdin, it scans `~/.claude/sessions/*.json` to find the file matching the current `session_id`, extracting `cwd` and `pid`.

The `cwd` field is included in the first message sent to the socket for each session.

### 2.2 Fallback Path: Buddy App

When `SessionManager` receives a message with no `cwd`, it scans `~/.claude/sessions/*.json` on disk, matching by `sessionId`. Results are cached in `SessionInfo`. This scan runs at most once per session.

### 2.3 Label Auto-Generation

```
cwd = "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy"
→ label = "claude-code-buddy"
```

If multiple sessions share the same directory (e.g. worktrees), append a disambiguation suffix:
```
session 1: "claude-code-buddy"
session 2: "claude-code-buddy②"
```

### 2.4 Color Assignment

`SessionManager` maintains a `usedColors: Set<SessionColor>` tracker. On session creation, the first unused color from `SessionColor.allCases` is assigned. On session removal, the color is returned to the pool.

## 3. Visual Layer: Labels & Color Coding

### 3.1 Cat Label (SKLabelNode)

Added as a child node of `CatSprite.node`:
- Position: ~8px above the sprite top
- Font: system font, 11px, bold
- Color: session's `SessionColor.nsColor`
- Shadow: `shadowColor` matching the session color at 0.4 alpha, `shadowBlur` for glow effect
- Updated when `SessionInfo.label` changes (via `set_label` or initial assignment)

### 3.2 Sprite Color Tinting

Use `SKSpriteNode.colorBlendFactor = 0.3` with the session color. This tints the pixel art without destroying the original style. When no textures are loaded (placeholder mode), the node color is set to the session color directly.

### 3.3 Shared Color File

Buddy app writes `/tmp/claude-buddy-colors.json` on every color assignment/update:

```json
{
  "cb57be8a-...": {"color": "coral", "hex": "#FF6B6B", "label": "buddy"},
  "9a3f12bc-...": {"color": "teal", "hex": "#4ECDC4", "label": "api-service"}
}
```

This file is read by the terminal-side statusline script.

## 4. Interaction Layer: Mouse Events

### 4.1 Mouse Event Strategy

The `BuddyWindow` is click-through (`ignoresMouseEvents = true`). To support hover and click on cats:

1. `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` — tracks mouse position globally (no Accessibility permission required)
2. Convert screen coordinates to scene coordinates and test against each cat's hitbox (48x48, slightly larger than the 32x32 sprite)
3. When mouse enters any cat's hitbox: set `window.ignoresMouseEvents = false`
4. When mouse leaves all hitboxes: delay 200ms, then set `window.ignoresMouseEvents = true`
5. `NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown])` — handles clicks when the window is interactive

New file: `Sources/ClaudeCodeBuddy/Window/MouseTracker.swift`

### 4.2 Hover Tooltip

Implemented as an `SKNode` subtree (not NSPopover, to avoid window focus issues):

Contents:
- Color dot + label + state badge
- `cwd` path (monospace)
- PID + last activity time
- Footer hint: "点击跳转到终端窗口"

Appears above the hovered cat with `SKAction.fadeIn(withDuration: 0.15)`. Dismissed with `SKAction.fadeOut(withDuration: 0.15)` when mouse leaves.

New file: `Sources/ClaudeCodeBuddy/Scene/TooltipNode.swift`

### 4.3 Click-to-Activate: Ghostty Tab Targeting

**Matching strategy (3-tier fallback):**

| Priority | Method | Reliability |
|----------|--------|-------------|
| 1 | Tab title marker | Highest — hook injects unique `●label` into Ghostty tab title via `set_tab_title` action |
| 2 | working directory | High — unique across different projects |
| 3 | terminal name | Medium — Claude Code's session title, for disambiguation |

**Tab title injection:**

On the first hook message for a session, `buddy-hook.sh` asynchronously sets the Ghostty tab title. Since multiple sessions may share the same `cwd` (e.g. worktrees), the script first queries `~/.claude/sessions/*.json` to find the current session's PID, then uses `ps -o tty= -p $PID` to get its TTY. It matches the terminal by comparing the TTY with Ghostty's terminal name (which often contains the TTY path). If TTY matching fails, it falls back to `working directory` matching, targeting only terminals whose title has not yet been set (i.e., does not contain `●`):

```bash
osascript -e "
  tell application \"Ghostty\"
    repeat with t in terminals of every tab of every window
      if working directory of t is \"$CWD\" and name of t does not contain \"●\" then
        perform action \"set_tab_title:●${LABEL}\" on t
        return
      end if
    end repeat
  end tell
" &
```

The `does not contain "●"` guard prevents overwriting an already-labeled terminal when two sessions share the same directory.

**Activation flow:**

```swift
func activateGhosttyTab(for session: SessionInfo) {
    let script = """
    tell application "Ghostty"
      repeat with w in windows
        repeat with t in tabs of w
          set term to focused terminal of t
          if name of term contains "●\(session.label)" then
            focus term
            return
          end if
        end repeat
      end repeat
    end tell
    """
    NSAppleScript(source: script)?.executeAndReturnError(nil)
}
```

**Terminal adapter protocol for future extensibility:**

```swift
protocol TerminalAdapter {
    func canHandle(bundleIdentifier: String) -> Bool
    func activateTab(for session: SessionInfo) -> Bool
}
```

New file: `Sources/ClaudeCodeBuddy/Terminal/TerminalAdapter.swift`
New file: `Sources/ClaudeCodeBuddy/Terminal/GhosttyAdapter.swift`

Default fallback: `NSRunningApplication(processIdentifier: pid).activate()`.

## 5. Menu Bar Dashboard

### 5.1 NSPopover Replacement

Replace the current `NSMenu` in `AppDelegate.setupMenuBar()` with an `NSPopover` containing a custom `NSViewController`.

New files:
- `Sources/ClaudeCodeBuddy/MenuBar/SessionPopoverController.swift`
- `Sources/ClaudeCodeBuddy/MenuBar/SessionRowView.swift`

### 5.2 Popover Content

- Header: "Claude Code Buddy" + session count
- Session list: one row per session, showing color dot, label, state badge, cwd, last activity time
- Each row is clickable → triggers `TerminalAdapter.activateTab()`
- Idle sessions rendered at 0.7 opacity
- Footer: "点击 session 跳转终端" + Quit button

### 5.3 Data Binding

`SessionManager` exposes `onSessionsChanged: (([SessionInfo]) -> Void)?` callback. The popover subscribes to this callback and refreshes its view on each change.

## 6. AI Label Integration

### 6.1 buddy-label CLI

New file: `plugin/scripts/buddy-label.sh` (~20 lines)

```bash
#!/usr/bin/env bash
# Usage: buddy-label "新标签名"
LABEL="$1"
# Find current session_id from ~/.claude/sessions/ by matching current PID ancestry
# Send set_label message to /tmp/claude-buddy.sock
# Also update Ghostty tab title via AppleScript
```

### 6.2 AI Awareness

The hook script returns a `message` field on `SessionStart` events, injecting a system prompt:

```
你的 Claude Code Buddy session：颜色 = coral (●)，标签 = "claude-code-buddy"。
如果当前任务有更好的描述名称，执行: buddy-label "新名称"
```

This lets the AI naturally discover and use the labeling capability without user intervention.

### 6.3 Terminal Statusline

A helper script or user guide for modifying `~/.claude/statusline-command.sh` to read `/tmp/claude-buddy-colors.json` and display a color-coded dot + label at the beginning of the statusline:

```
● buddy | opus-4-6 | ctx 87%
```

ANSI 256-color codes are used to map `SessionColor.hex` to terminal colors.

## 7. Delivery Phases

| Phase | Scope | Dependencies |
|-------|-------|-------------|
| **P1: Foundation** | SessionInfo model, cwd enrichment, SessionColor, label SKLabelNode, sprite tinting, color file | None |
| **P2: Interaction** | MouseTracker, dynamic click-through, TooltipNode, GhosttyAdapter click-to-activate | P1 |
| **P3: Dashboard** | NSPopover menu bar, SessionPopoverController, SessionRowView | P1 |
| **P4: AI Integration** | buddy-label CLI, set_label protocol, hook system prompt injection, statusline guide | P1 |

P2, P3, P4 are independent of each other and can be developed in parallel after P1.

## 8. New/Modified Files Summary

### New Files
- `Sources/ClaudeCodeBuddy/Session/SessionInfo.swift`
- `Sources/ClaudeCodeBuddy/Session/SessionColor.swift`
- `Sources/ClaudeCodeBuddy/Window/MouseTracker.swift`
- `Sources/ClaudeCodeBuddy/Scene/TooltipNode.swift`
- `Sources/ClaudeCodeBuddy/Terminal/TerminalAdapter.swift`
- `Sources/ClaudeCodeBuddy/Terminal/GhosttyAdapter.swift`
- `Sources/ClaudeCodeBuddy/MenuBar/SessionPopoverController.swift`
- `Sources/ClaudeCodeBuddy/MenuBar/SessionRowView.swift`
- `plugin/scripts/buddy-label.sh`

### Modified Files
- `Sources/ClaudeCodeBuddy/Network/HookMessage.swift` — add `cwd`, `label`, `.setLabel`
- `Sources/ClaudeCodeBuddy/Session/SessionManager.swift` — SessionInfo tracking, color assignment, enrichment logic, `onSessionsChanged` callback
- `Sources/ClaudeCodeBuddy/Scene/CatSprite.swift` — label node, color tinting
- `Sources/ClaudeCodeBuddy/Scene/BuddyScene.swift` — tooltip management, mouse hit testing
- `Sources/ClaudeCodeBuddy/Window/BuddyWindow.swift` — dynamic `ignoresMouseEvents`
- `Sources/ClaudeCodeBuddy/App/AppDelegate.swift` — MouseTracker setup, popover menu bar
- `hooks/buddy-hook.sh` — cwd extraction, Ghostty tab title injection
- `plugin/scripts/buddy-hook.sh` — same changes as above
- `plugin/hooks/hooks.json` — register buddy-label.sh
