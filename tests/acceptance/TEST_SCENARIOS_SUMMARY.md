# Acceptance Test Scenarios: Random Walk Jump Bug Fix

## Overview

This document summarizes the acceptance test scenarios generated for fixing a SpriteKit physics bug in the Claude Code Buddy macOS desktop app.

## Bug Summary

**Issue**: When a cat in toolUse state (random walk) encounters another cat blocking its path, it doesn't jump over. Instead, it gets stuck running in place.

**Root Cause**: Random walk jumps don't disable physics dynamics (`isDynamic = false`), causing collision detection to trigger during the jump arc and blocking the cat.

**Fix**: Disable physics dynamics during random walk jumps, matching the existing behavior of exit scene jumps (MovementComponent.swift:259).

## Test Scenarios

### 1. Normal Case: Single Obstacle Jump

**Purpose**: Verify the primary fix works - cat jumps over a single obstacle during random walk.

**Pre-conditions**:
- App is running and stable
- No cats on screen initially
- Unix socket server active at `/tmp/claude-buddy.sock`

**Test Steps**:
```bash
# Create walker and blocker cats
echo '{"event":"session_start","session_id":"debug-walker","timestamp":0}' | nc -U /tmp/claude-buddy.sock
sleep 0.5
echo '{"event":"session_start","session_id":"debug-blocker1","timestamp":0}' | nc -U /tmp/claude-buddy.sock
sleep 0.5

# Enter toolUse state (random walk)
echo '{"event":"tool_start","session_id":"debug-walker","tool":"Edit","timestamp":0}' | nc -U /tmp/claude-buddy.sock
echo '{"event":"tool_start","session_id":"debug-blocker1","tool":"Edit","timestamp":0}' | nc -U /tmp/claude-buddy.sock
```

**Expected Observable Outcome**:
- Both cats display name labels (debug- prefix enables permanent labels)
- Walker begins random walk in ±120px range from origin
- When walker encounters blocker1:
  - Approaches to ~20px before obstacle
  - Executes smooth Bezier arc jump (50px height above ground)
  - Plays jump animation frames
  - Lands ~20px past obstacle
  - Continues random walk normally
- Walker **never gets stuck running in place** against the obstacle
- Both cats remain stable for 10+ seconds

**Failure Indicators**:
- Walker repeatedly walks toward blocker but stops/gets stuck
- Animation continues but position doesn't change (running in place)
- Physics collision causes jitter or instability
- App crashes or freezes

---

### 2. Edge Case: Two Obstacles in Sequence

**Purpose**: Verify jump logic handles multiple consecutive obstacles correctly.

**Pre-conditions**: Same as Scenario 1

**Test Steps**:
```bash
# Create three cats
echo '{"event":"session_start","session_id":"debug-walker2","timestamp":0}' | nc -U /tmp/claude-buddy.sock
sleep 0.5
echo '{"event":"session_start","session_id":"debug-blocker2","timestamp":0}' | nc -U /tmp/claude-buddy.sock
sleep 0.5
echo '{"event":"session_start","session_id":"debug-blocker3","timestamp":0}' | nc -U /tmp/claude-buddy.sock
sleep 0.5

# All in toolUse state
echo '{"event":"tool_start","session_id":"debug-walker2","tool":"Edit","timestamp":0}' | nc -U /tmp/claude-buddy.sock
echo '{"event":"tool_start","session_id":"debug-blocker2","tool":"Edit","timestamp":0}' | nc -U /tmp/claude-buddy.sock
echo '{"event":"tool_start","session_id":"debug-blocker3","tool":"Edit","timestamp":0}' | nc -U /tmp/claude-buddy.sock
```

**Expected Observable Outcome**:
- All three cats display name labels
- Walker2 navigates random walk path
- When approaching blocker2 then blocker3:
  - First jump: clears blocker2, lands smoothly
  - Second jump: clears blocker3, lands smoothly
  - Both jumps execute without collision detection
- Walker2 continues random walk after clearing both obstacles
- No collision or stuck behavior during either jump

**Failure Indicators**:
- Walker2 gets stuck on first obstacle
- First jump succeeds but second fails
- Jumps overlap or cause physics conflicts
- Walker2 "glitches" or teleports

---

### 3. Edge Case: State Change Interrupts Jump Mid-Flight

**Purpose**: Verify state machine correctly handles interrupted jumps and restores physics.

**Pre-conditions**: Same as Scenario 1

**Test Steps**:
```bash
# Setup cats
echo '{"event":"session_start","session_id":"debug-jumper","timestamp":0}' | nc -U /tmp/claude-buddy.sock
echo '{"event":"session_start","session_id":"debug-blocker4","timestamp":0}' | nc -U /tmp/claude-buddy.sock
sleep 0.5

# Start random walk
echo '{"event":"tool_start","session_id":"debug-jumper","tool":"Edit","timestamp":0}' | nc -U /tmp/claude-buddy.sock
echo '{"event":"tool_start","session_id":"debug-blocker4","tool":"Edit","timestamp":0}' | nc -U /tmp/claude-buddy.sock
sleep 1.0

# Force state change mid-walk (simulate tool completion)
echo '{"event":"tool_end","session_id":"debug-jumper","tool":"Edit","timestamp":0}' | nc -U /tmp/claude-buddy.sock
sleep 0.2
echo '{"event":"idle","session_id":"debug-jumper","timestamp":0}' | nc -U /tmp/claude-buddy.sock
```

**Expected Observable Outcome**:
- Walker starts random walk and may begin a jump
- When tool_end/idle event arrives:
  - Jump sequence cleanly interrupted
  - Cat transitions to idle animation immediately
  - Physics `isDynamic` restored to `true`
  - Cat settles at current position
- No stuck animations or "ghost" jump actions
- Cat can be moved/manipulated normally after state change
- Blocker4 continues its own random walk unaffected

**Failure Indicators**:
- Jump animation continues despite state change
- Cat remains in mid-air position
- Physics not restored (cat stuck, can't be moved)
- Visual glitch (wrong position/state)

---

### 4. Edge Case: Cat Lands After Jump and Continues Random Walk

**Purpose**: Verify post-jump behavior is correct and physics are properly restored.

**Pre-conditions**: Same as Scenario 1

**Test Steps**:
```bash
# Setup cats
echo '{"event":"session_start","session_id":"debug-continuer","timestamp":0}' | nc -U /tmp/claude-buddy.sock
echo '{"event":"session_start","session_id":"debug-blocker5","timestamp":0}' | nc -U /tmp/claude-buddy.sock
sleep 0.5

# Start toolUse and observe for 10+ seconds
echo '{"event":"tool_start","session_id":"debug-continuer","tool":"Edit","timestamp":0}' | nc -U /tmp/claude-buddy.sock
echo '{"event":"tool_start","session_id":"debug-blocker5","tool":"Edit","timestamp":0}' | nc -U /tmp/claude-buddy.sock

# Observe behavior for 10 seconds (watch for multiple walk/jump cycles)
```

**Expected Observable Outcome**:
- Walker performs initial random walk steps
- When encountering blocker5:
  - Jump arc executes smoothly
  - Cat lands at correct ground position
  - Physics dynamics restored (`isDynamic = true`)
- After landing:
  - Walker continues random walk normally
  - Next random walk step executes correctly
  - Animation switches walk → idle → walk as expected
- Over 10+ seconds: multiple walk/jump cycles without issues
- No degradation in behavior over time

**Failure Indicators**:
- First jump works but subsequent walks broken
- Walker gets "stuck" in a state after landing
- Animation stops switching correctly
- Performance degrades or FPS drops

---

### 5. Regression: Exit Scene Jumps Still Work Correctly

**Purpose**: Ensure the fix doesn't break existing exit scene jump behavior.

**Pre-conditions**: Same as Scenario 1

**Test Steps**:
```bash
# Create exiting cat and obstacle
echo '{"event":"session_start","session_id":"debug-exiter","timestamp":0}' | nc -U /tmp/claude-buddy.sock
echo '{"event":"session_start","session_id":"debug-blocker6","timestamp":0}' | nc -U /tmp/claude-buddy.sock
sleep 0.5

# Position cats in idle state first
echo '{"event":"idle","session_id":"debug-exiter","timestamp":0}' | nc -U /tmp/claude-buddy.sock
echo '{"event":"idle","session_id":"debug-blocker6","timestamp":0}' | nc -U /tmp/claude-buddy.sock
sleep 0.5

# Trigger exit
echo '{"event":"session_end","session_id":"debug-exiter","timestamp":0}' | nc -U /tmp/claude-buddy.sock
```

**Expected Observable Outcome**:
- Exiter cat walks toward nearest screen edge
- If blocker6 is on exit path:
  - Exiter approaches blocker6
  - Executes jump arc over blocker6
  - Continues walking off-screen
  - Physics `isDynamic = false` during jump (prevents collision)
  - Blocker6 may show fright reaction (hop/scared animation)
- Exiter smoothly exits the screen
- No regression in existing exit behavior

**Failure Indicators**:
- Exiter crashes into blocker6
- Exit animation looks different/broken
- Jump doesn't execute or looks wrong
- App crashes during exit
- Blocker6 shows incorrect reaction

---

### 6. Regression: Food Walk Behavior Not Affected

**Purpose**: Ensure the fix doesn't impact food walk (different code path).

**Pre-conditions**:
- App is running
- No cats on screen
- Food spawning mechanism active (automatic or via UI)

**Test Steps**:
```bash
# Create cat in idle state
echo '{"event":"session_start","session_id":"debug-food-walker","timestamp":0}' | nc -U /tmp/claude-buddy.sock
sleep 0.5

echo '{"event":"idle","session_id":"debug-food-walker","timestamp":0}' | nc -U /tmp/claude-buddy.sock
sleep 0.5

# Wait for food to spawn (automatic) or trigger via UI
# Cat should walk to food and eat
```

**Expected Observable Outcome**:
- Cat displays name label in idle state
- When food spawns:
  - Cat shows excited reaction (hop + paw frame)
  - Walks toward food with walk-a animation
  - Does NOT jump over obstacles (food walk has different logic)
  - Reaches food and starts eating animation
- Food walk behavior identical to pre-fix behavior
- No physics-related issues during food walk

**Failure Indicators**:
- Cat doesn't respond to food
- Food walk animation broken
- Cat jumps during food walk (incorrect behavior)
- App crashes when food appears

---

## Test Execution

### Automated Tests
```bash
# Run all acceptance tests including random walk jump tests
cd tests/acceptance
./run-all.sh

# Run only random walk jump tests
./test-random-walk-jumps.acceptance.sh
```

### Manual Tests
```bash
# Build and run the app
make build
make run

# In a separate terminal, execute test scenarios manually
# See MANUAL_TESTING_RANDOM_WALK_JUMPS.md for detailed procedures
```

## Test Files

1. **Automated Test**: `tests/acceptance/test-random-walk-jumps.acceptance.sh`
   - Shell script testing stability and state transitions
   - Verifies no crashes and proper event handling
   - Integrated into main test runner (`run-all.sh`)

2. **Manual Testing Guide**: `tests/acceptance/MANUAL_TESTING_RANDOM_WALK_JUMPS.md`
   - Detailed step-by-step procedures for each scenario
   - Visual verification checklists
   - Troubleshooting guide
   - Known limitations

## Key Components Involved

- **MovementComponent.swift** (lines 87-95): Random walk jump logic - where fix is applied
- **MovementComponent.swift** (line 259): Exit scene jump with `isDynamic = false` - reference implementation
- **JumpComponent.swift** (`buildJumpActions`): Bezier arc jump action builder
- **CatEntity.swift**: Physics body setup (44x44) and state machine
- **CatToolUseState.swift**: ToolUse state entry/exit handling

## Physics Behavior

**Before Fix**:
- Random walk jumps keep `isDynamic = true`
- Collision detection active during jump
- Cat collides with obstacle and gets stuck
- Position jitters or cat runs in place

**After Fix**:
- Random walk jumps set `isDynamic = false` (before jump)
- Collision disabled during jump arc
- Cat follows smooth Bezier path over obstacle
- Physics restored to `isDynamic = true` after landing

**Reference Behavior** (Exit Scene Jumps):
- Already had `isDynamic = false` during jumps
- Used as reference for the fix
- Tested in regression scenario 5

## Success Criteria

The bug fix is considered successful when:

1. **All automated tests pass** (no crashes, stable state transitions)
2. **All manual test scenarios pass** (visual verification)
3. **No regressions** in exit jump behavior
4. **No regressions** in food walk behavior
5. **Performance maintained** (no FPS drops, memory stable)

## References

- Bug Fix Location: `Sources/ClaudeCodeBuddy/Entity/Components/MovementComponent.swift`
- Reference Implementation: MovementComponent.swift:259 (exit scene jumps)
- Constants: `Sources/ClaudeCodeBuddy/Entity/Cat/CatConstants.swift`
- Physics Setup: `Sources/ClaudeCodeBuddy/Entity/Cat/CatEntity.swift:156` (setupPhysicsBody)
