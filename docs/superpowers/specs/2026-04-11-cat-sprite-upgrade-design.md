# Cat Sprite Upgrade Design

Upgrade the cat from procedurally generated 32x32 placeholder sprites to high-quality open-source pixel art with richer animations and natural idle behaviors.

## Problem

The current cat is procedurally generated using CoreGraphics — an ellipse body, circle head, triangle ears, and Bezier tail. It reads as a colored blob, not a real cat. The 4-frame animations per state are minimal and repetitive.

## Solution

Replace all sprite assets with frames extracted from the open-source **"2D Pixel Art Cat Sprites"** sprite sheet (itch.io game ID 1070070). Upscale from 32x32 to 48x48 using nearest-neighbor interpolation. Implement a richer idle state machine with randomized micro-animations.

## Asset Source

- **Name:** 2D Pixel Art Cat Sprites
- **Source:** itch.io (game ID 1070070)
- **Size:** 32x32 per frame (will be upscaled to 48x48)
- **License:** Free for commercial and non-commercial use
- **Available animations:** idle (x2 variants), clean (x2 variants), movement (x2 variants), sleep, paw, jump, scared

## State-to-Animation Mapping

| CatState | Source Animations | Frame Rate | Behavior |
|---|---|---|---|
| **idle** | idle + clean + sleep (randomized) | 0.2s/frame (5 FPS) | Rich idle state machine with random micro-animations |
| **thinking** | scared + paw | 0.15s/frame (~7 FPS) | Nervous/alert posture to convey "processing" |
| **coding** | clean | 0.12s/frame (~8 FPS) | Cat grooming — a natural, "busy" cat behavior |
| **enter** | movement (walk) | 0.6s total | Walk in from above (existing drop-in preserved) |
| **exit** | movement (walk) | speed-based | Walk toward nearest edge, then removed |

## Idle State Machine

The idle state is no longer a single looping animation. Instead, it cycles through sub-states with weighted random transitions:

```
┌─────────────────────────────────────────────────┐
│                  Idle State Machine              │
│                                                  │
│   idle_breathe (base loop, 70% weight)           │
│       │                                          │
│       ├── 15% ──► idle_blink (2s, return)        │
│       ├── 10% ──► clean (舔毛, ~3s, return)       │
│       └──  5% ──► sleep (打盹, ~5s, return)       │
│                                                  │
│   Transition check: every 4-6 seconds            │
│   (randomized interval to avoid mechanical feel) │
└─────────────────────────────────────────────────┘
```

- **idle_breathe**: Base idle animation using idle variant 1, looping
- **idle_blink**: Uses idle variant 2 (different eye frame), plays once then returns
- **clean**: Uses clean animation frames, plays full cycle then returns to breathe
- **sleep**: Uses sleep animation frames, holds for ~5 seconds then returns to breathe

When transitioning out of idle (to thinking/coding), any sub-animation completes its current frame before switching.

## Sprite Asset Pipeline

### Step 1: Download & Extract
- Download the sprite sheet from itch.io
- The sheet is organized as strips — each animation is a horizontal row of frames

### Step 2: Slice into Individual Frames
- Write a Swift script (`Scripts/slice-sprites.swift`) to:
  - Load the sprite sheet PNG
  - Cut each 32x32 frame
  - Upscale to 48x48 using nearest-neighbor (no anti-aliasing)
  - Save as individual PNGs

### Step 3: Naming Convention
New file naming scheme (replacing the old `cat-{state}-{frame}.png`):

```
Assets/Sprites/
  cat-idle-a-1.png ... cat-idle-a-N.png     (idle variant A)
  cat-idle-b-1.png ... cat-idle-b-N.png     (idle variant B / blink)
  cat-clean-1.png  ... cat-clean-N.png      (clean / grooming)
  cat-sleep-1.png  ... cat-sleep-N.png      (sleep)
  cat-scared-1.png ... cat-scared-N.png     (scared)
  cat-paw-1.png    ... cat-paw-N.png        (paw)
  cat-walk-a-1.png ... cat-walk-a-N.png     (movement variant A)
  cat-walk-b-1.png ... cat-walk-b-N.png     (movement variant B)
  cat-jump-1.png   ... cat-jump-N.png       (jump, reserved for future)
```

Exact frame counts TBD after inspecting the downloaded sprite sheet.

## Code Changes

### `CatSprite.swift` — Major Changes

1. **Texture loading**: Update to load new file names and support variable frame counts per animation
2. **Idle state machine**: Add `IdleSubState` enum (`.breathe`, `.blink`, `.clean`, `.sleep`) with weighted random transitions on a timer
3. **State animations**:
   - `thinking` → load scared + paw textures
   - `coding` → load clean textures
   - `enter/exit` → load walk textures
4. **Physics body**: Adjust from `rectangleOf: CGSize(width: 28, height: 28)` to `CGSize(width: 44, height: 44)`
5. **Sprite rendering**: Ensure `SKTexture.filteringMode = .nearest` preserved for pixel-crisp upscaling

### `BuddyScene.swift` — Minor Adjustments

1. Ground node and spawn position calculations updated for 48px sprite height
2. Cat spawn Y position: `sceneHeight + 48` (was `+ 32`)
3. Ground position: `y = 48` (was `y = 32`)
4. Exit boundary: `x = -48` or `x = sceneWidth + 48`

### `generate-placeholders.swift` → `Scripts/slice-sprites.swift`

Replace the procedural generation script with a sprite sheet slicing + upscaling utility:
- Input: raw sprite sheet PNG + slice configuration (row/column layout, frame size)
- Output: individual 48x48 PNGs in `Assets/Sprites/`

## Files Changed

| File | Change Type | Scope |
|---|---|---|
| `Assets/Sprites/*.png` | Replace all | 19 old PNGs removed, ~20-30 new PNGs added |
| `Scene/CatSprite.swift` | Major rewrite | Texture loading, idle state machine, state mapping |
| `Scene/BuddyScene.swift` | Minor update | Coordinate adjustments for 48px sprites |
| `Scripts/generate-placeholders.swift` | Replace | Becomes `slice-sprites.swift` |

## Files NOT Changed

- `App/main.swift` — no changes
- `App/AppDelegate.swift` — no changes
- `Window/BuddyWindow.swift` — no changes
- `Window/DockTracker.swift` — no changes
- `Network/SocketServer.swift` — no changes
- `Network/HookMessage.swift` — no changes
- `Session/SessionManager.swift` — no changes
- `hooks/buddy-hook.sh` — no changes
- `plugin/` — no changes

## Attribution

The sprite sheet credits should be added to README.md:

```
## Credits

- Cat sprites: "2D Pixel Art Cat Sprites" from itch.io (free for commercial/non-commercial use)
```

## Open Questions

None — all design decisions are resolved.
