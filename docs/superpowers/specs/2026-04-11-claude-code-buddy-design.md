# Claude Code Buddy - Design Spec

A macOS desktop companion that visualizes Claude Code session states through pixel-art cats living on top of the Dock.

## Overview

Each active Claude Code session spawns a pixel-art cat that sits on the Dock's upper edge. The cat's behavior reflects the session's current state — napping when idle, tail-wagging when thinking, dashing around when coding. Multiple sessions produce multiple cats that coexist with physics-based collision.

## Technical Stack

- **Language:** Swift
- **Rendering:** SpriteKit (2D sprite animation + physics engine)
- **Window:** NSWindow (transparent, borderless, floating)
- **Communication:** Unix Domain Socket (`/tmp/claude-buddy.sock`)
- **State source:** Claude Code Hooks (shell scripts that fire on session events)

## Architecture

```
┌────────────────────────────────────────────────────┐
│                Claude Code Buddy (macOS App)        │
│                                                    │
│  ┌──────────────┐     ┌────────────────┐           │
│  │ BuddyWindow  │     │ SessionManager │           │
│  │ (transparent) │     │                │           │
│  │              │     │  SocketServer  │           │
│  │  SpriteKit   │◄────┤  (UDS listen)  │           │
│  │  BuddyScene  │     │                │           │
│  │              │     │  HookMessage   │           │
│  │  CatSprite[] │     │  (JSON parse)  │           │
│  └──────────────┘     └───────┬────────┘           │
│                               │                    │
└───────────────────────────────┼────────────────────┘
                                │ Unix Domain Socket
                                │ /tmp/claude-buddy.sock
┌───────────────────────────────┼────────────────────┐
│  Claude Code Hooks            │                    │
│  buddy-hook.sh ──► JSON ──────┘                    │
└────────────────────────────────────────────────────┘
```

Three layers:

1. **BuddyWindow** — Transparent floating window + SpriteKit scene. Renders all cats.
2. **SessionManager** — Manages session lifecycles. Each session maps to one CatSprite. Runs a Unix Domain Socket server to receive hook events.
3. **Claude Code Hooks** — Lightweight shell script (`buddy-hook.sh`) that sends one-line JSON to the socket on each event.

## Dock Detection & Window Positioning

The app positions a transparent full-width window directly above the Dock.

**Detection algorithm:**

```swift
let screenFrame = NSScreen.main!.frame           // full screen
let visibleFrame = NSScreen.main!.visibleFrame    // minus Dock & menu bar

// Dock at bottom:
let dockHeight = visibleFrame.origin.y - screenFrame.origin.y

// BuddyWindow placement:
window.setFrame(NSRect(
    x: screenFrame.origin.x,
    y: screenFrame.origin.y + dockHeight,   // sits on Dock top edge
    width: screenFrame.width,                // full width
    height: 80                               // cat activity zone
), display: true)
```

**Behaviors:**

- **Dock movement detection:** Listen to `NSApplication.didChangeScreenParametersNotification` to reposition when Dock moves.
- **Dock auto-hide:** When Dock is hidden, cats fall to the screen's bottom edge.
- **Window level:** `.floating` — above normal windows, below fullscreen apps.
- **Click-through:** Transparent areas pass clicks through. Only cat pixels are interactive.

## Cat State Machine

### States

Three MVP states, each with dedicated sprite animations:

| State | Trigger | Cat Behavior | Frame Rate |
|-------|---------|-------------|-----------|
| **Idle** | Session waiting for user input | Napping, grooming, stretching, slow tail wag | 4-6 FPS |
| **Thinking** | Claude generating a response | Sitting, fast tail wag, head tilted, ears perked | 6-8 FPS |
| **Coding** | Tool call in progress (Edit/Write/Bash) | Running back and forth, paw tapping, tail up | 8-12 FPS |

### State Transitions

```
             user_prompt          tool_start
  Idle ──────────────────► Thinking ──────────────► Coding
   ▲                          │  ▲                    │
   │    response_done         │  │    tool_end        │
   │◄─────────────────────────┘  │◄───────────────────┘
   │                                                  │
   │◄─────────────── session_end ─────────────────────┘
   (exit animation → remove cat)
```

### Animation Details

- **Transition:** 0.3s blend between states (e.g., sitting → standing) to avoid hard cuts.
- **Sub-animations:** Each state has 2-3 random sub-animations to prevent monotony (e.g., idle alternates between napping and grooming).
- **Enter animation:** New session → cat runs in from a random screen edge with a small hop.
- **Exit animation:** Session end → cat yawns, slowly walks off screen edge, then removed.

## Communication Protocol

### Hook Script → Buddy App

The hook script sends one-line JSON messages over a Unix Domain Socket.

**Message format:**

```json
{
  "session_id": "abc123",
  "event": "thinking",
  "tool": null,
  "timestamp": 1713000000
}
```

**Event types:**

| Claude Code Hook | Event Sent | Resulting Cat State |
|-----------------|-----------|-------------------|
| Notification (assistant reply starts) | `thinking` | Thinking |
| PreToolUse (Edit/Write/Bash) | `tool_start` | Coding |
| PostToolUse | `tool_end` | Thinking |
| Stop / idle before user input | `idle` | Idle |
| Session exit | `session_end` | Exit animation → remove |

**Hook script (`buddy-hook.sh`):** Uses `socat` or `nc -U` to send a single JSON line to `/tmp/claude-buddy.sock`. The script is stateless — the buddy app tracks session state.

## Multi-Cat Management

### SpriteKit Scene Structure

```
BuddyScene (SKScene)
├── groundNode          ← physics ground at y=0, aligned to Dock top
├── catNode_session_A   ← CatSprite with physics body
├── catNode_session_B
└── catNode_session_C
```

### Rules

- One cat per session, identified by `session_id`.
- Cats have physics collision — they push each other, never overlap.
- New cats spawn at random horizontal positions across the Dock width.
- Maximum **8 simultaneous cats**. When exceeded, the earliest idle cat auto-exits.
- SpriteKit physics engine handles gravity and ground collision automatically.

### CatSprite Class

```swift
class CatSprite {
    let sessionId: String
    var currentState: CatState   // .idle, .thinking, .coding
    var animations: [CatState: [SKTexture]]
    
    func switchState(to newState: CatState)  // transition animation + loop
    func enterScene()                         // run-in animation
    func exitScene()                          // walk-out animation
}
```

## Sprite Assets

- **Size:** 32x32 pixels (renders at 64x64 pt on Retina)
- **Style:** Pixel art
- **Frames per state:** 4-6
- **Enter/exit frames:** ~4 each
- **Total MVP frames:** ~20-24 PNG images

## Project Structure

```
claude-code-buddy/
├── ClaudeCodeBuddy/                  ← Xcode project
│   ├── App/
│   │   ├── ClaudeCodeBuddyApp.swift     ← entry point, menu bar icon
│   │   └── AppDelegate.swift             ← window creation, socket startup
│   ├── Window/
│   │   ├── BuddyWindow.swift             ← transparent borderless window
│   │   └── DockTracker.swift             ← Dock position detection & monitoring
│   ├── Scene/
│   │   ├── BuddyScene.swift              ← SpriteKit main scene + physics world
│   │   └── CatSprite.swift               ← cat node + state machine + animations
│   ├── Network/
│   │   ├── SocketServer.swift            ← Unix Domain Socket listener
│   │   └── HookMessage.swift             ← JSON message parsing
│   ├── Session/
│   │   └── SessionManager.swift          ← multi-session lifecycle management
│   └── Assets/
│       └── Sprites/
│           ├── cat-idle-1..6.png
│           ├── cat-thinking-1..6.png
│           ├── cat-coding-1..6.png
│           ├── cat-enter-1..4.png
│           └── cat-exit-1..4.png
├── hooks/
│   └── buddy-hook.sh                    ← Claude Code hook script
└── docs/
```

## MVP Scope

### Included

- Transparent window anchored above Dock (bottom position only)
- 3-state pixel cat animations (idle / thinking / coding)
- Multi-cat coexistence with physics collision
- Enter/exit animations for session start/end
- Unix Domain Socket communication
- Claude Code hook script
- Menu bar icon (with quit option)

### Excluded

- Cat appearance customization (colors, breeds)
- Sound effects
- Settings UI / preferences window
- Dock left/right side support (bottom only)
- Cat click interactions (petting, etc.)
- Multi-monitor support
