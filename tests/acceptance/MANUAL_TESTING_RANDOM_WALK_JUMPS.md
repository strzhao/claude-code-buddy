# Manual Testing Guide: Random Walk Jump Bug Fix

## Bug Description
When a cat is doing random walk (toolUse state) and encounters another cat blocking its path, it doesn't jump over. Instead, it gets stuck running in place.

## Fix Applied
Disabled physics dynamics (`isDynamic = false`) during random walk jumps, similar to how exit scene jumps already work. This prevents collision detection during the jump arc.

## Test Setup

### Prerequisites
```bash
make build
make run
```

### Socket Testing Helper
```bash
# Function to send events to the running app
send_event() {
    local sid="$1"
    local evt="$2"
    local tool="${3:-null}"
    local ts=$(date +%s)
    if [ "$tool" = "null" ]; then
        echo "{\"session_id\":\"$sid\",\"event\":\"$evt\",\"tool\":null,\"timestamp\":$ts}" | nc -U /tmp/claude-buddy.sock
    else
        echo "{\"session_id\":\"$sid\",\"event\":\"$evt\",\"tool\":\"$tool\",\"timestamp\":$ts}" | nc -U /tmp/claude-buddy.sock
    fi
}
```

---

## Test Scenarios

### Scenario 1: Single Obstacle Jump (Normal Case)

**Pre-conditions:**
- App is running
- No cats on screen

**Test Steps:**
```bash
# Create walker cat (will start at left side)
send_event "debug-walker" "session_start"
sleep 0.5

# Create blocker cat (will appear near center)
send_event "debug-blocker1" "session_start"
sleep 0.5

# Enter toolUse state (random walk)
send_event "debug-walker" "tool_start" "Edit"
send_event "debug-blocker1" "tool_start" "Edit"
```

**Expected Observable Outcome:**
1. Both cats display name labels (debug- prefix enables labels)
2. Walker cat begins walking randomly in ±120px range from its origin
3. When walker encounters blocker1, it should:
   - Approach the obstacle (walk to ~20px before it)
   - Execute a jump arc (cat rises ~50px above ground)
   - Play jump animation frames
   - Land ~20px past the obstacle
   - Continue random walk
4. Walker **never gets stuck running in place** against the obstacle
5. Both cats remain stable for 10+ seconds

**Failure Indicators:**
- Walker repeatedly walks toward blocker but stops/gets stuck
- Walker's animation continues but position doesn't change
- Walker collides and physics interaction causes jitter/instability
- App crashes or freezes

---

### Scenario 2: Two Obstacles in Sequence (Edge Case)

**Pre-conditions:**
- App is running
- No cats on screen

**Test Steps:**
```bash
# Create three cats spaced horizontally
send_event "debug-walker2" "session_start"
sleep 0.5
send_event "debug-blocker2" "session_start"
sleep 0.5
send_event "debug-blocker3" "session_start"
sleep 0.5

# All in toolUse state
send_event "debug-walker2" "tool_start" "Edit"
send_event "debug-blocker2" "tool_start" "Edit"
send_event "debug-blocker3" "tool_start" "Edit"
```

**Expected Observable Outcome:**
1. All three cats display name labels
2. Walker2 navigates random walk path
3. When walker2 approaches blocker2 then blocker3 in sequence:
   - First jump: clears blocker2, lands smoothly
   - Second jump: clears blocker3, lands smoothly
   - Both jumps execute without collision
4. Walker2 continues random walk after clearing both obstacles
5. No collision or stuck behavior during either jump

**Failure Indicators:**
- Walker2 gets stuck on first obstacle
- First jump succeeds but second jump fails
- Jumps overlap or cause physics conflicts
- Walker2 "glitches" or teleports

---

### Scenario 3: State Change During Jump (Edge Case)

**Pre-conditions:**
- App is running
- No cats on screen

**Test Steps:**
```bash
# Setup walker and obstacle
send_event "debug-jumper" "session_start"
send_event "debug-blocker4" "session_start"
sleep 0.5

# Start random walk
send_event "debug-jumper" "tool_start" "Edit"
send_event "debug-blocker4" "tool_start" "Edit"
sleep 1.0

# Force state change mid-walk (simulate tool completion)
send_event "debug-jumper" "tool_end" "Edit"
sleep 0.2
send_event "debug-jumper" "idle"
```

**Expected Observable Outcome:**
1. Walker starts random walk and may begin a jump
2. When tool_end/idle event arrives:
   - Jump sequence is cleanly interrupted
   - Cat transitions to idle animation immediately
   - Physics `isDynamic` is restored to `true`
   - Cat settles at its current position
3. No stuck animations or "ghost" jump actions
4. Cat can be moved/manipulated normally after state change
5. Blocker4 continues its own random walk unaffected

**Failure Indicators:**
- Jump animation continues despite state change
- Cat remains in mid-air position
- Physics not restored (cat stuck, can't be moved)
- Visual glitch (cat appears in wrong position/state)

---

### Scenario 4: Post-Jump Random Walk Continuation (Edge Case)

**Pre-conditions:**
- App is running
- No cats on screen

**Test Steps:**
```bash
# Setup walker and obstacle
send_event "debug-continuer" "session_start"
send_event "debug-blocker5" "session_start"
sleep 0.5

# Start toolUse and observe for 10+ seconds
send_event "debug-continuer" "tool_start" "Edit"
send_event "debug-blocker5" "tool_start" "Edit"

# Observe behavior for 10 seconds
# (watch for multiple random walk cycles including jumps)
```

**Expected Observable Outcome:**
1. Walker performs initial random walk steps
2. When walker encounters blocker5:
   - Jump arc executes smoothly
   - Cat lands at correct ground position
   - Physics dynamics restored (`isDynamic = true`)
3. After landing:
   - Walker continues random walk normally
   - Next random walk step executes correctly
   - Animation switches from walk → idle → walk as expected
4. Over 10+ seconds: multiple walk/jump cycles occur without issues
5. No degradation in behavior over time

**Failure Indicators:**
- First jump works but subsequent walks are broken
- Walker gets "stuck" in a state after landing
- Animation stops switching correctly
- Performance degrades or FPS drops over time

---

### Scenario 5: Exit Scene Jump Regression Test

**Pre-conditions:**
- App is running
- No cats on screen

**Test Steps:**
```bash
# Create exiting cat and obstacle
send_event "debug-exiter" "session_start"
send_event "debug-blocker6" "session_start"
sleep 0.5

# Position cats in idle state first
send_event "debug-exiter" "idle"
send_event "debug-blocker6" "idle"
sleep 0.5

# Trigger exit
send_event "debug-exiter" "session_end"
```

**Expected Observable Outcome:**
1. Exiter cat walks toward nearest screen edge
2. If blocker6 is on the exit path:
   - Exiter approaches blocker6
   - Executes jump arc over blocker6
   - Continues walking off-screen
   - Physics `isDynamic = false` during jump (prevents collision)
   - Blocker6 may show fright reaction (hop/scared animation)
3. Exiter smoothly exits the screen
4. No regression in existing exit behavior

**Failure Indicators:**
- Exiter crashes into blocker6
- Exit animation looks different/broken
- Jump doesn't execute or looks wrong
- App crashes during exit
- Blocker6 shows incorrect reaction

---

### Scenario 6: Food Walk Behavior (Regression Test)

**Pre-conditions:**
- App is running
- No cats on screen
- Food spawning mechanism active (automatic or via UI)

**Test Steps:**
```bash
# Create cat in idle state
send_event "debug-food-walker" "session_start"
sleep 0.5

send_event "debug-food-walker" "idle"
sleep 0.5

# Wait for food to spawn (automatic) or trigger via UI
# Cat should walk to food and eat
```

**Expected Observable Outcome:**
1. Cat displays name label in idle state
2. When food spawns (or is placed):
   - Cat shows excited reaction (hop + paw frame)
   - Walks toward food with walk-a animation
   - Does NOT jump over obstacles (food walk has different logic)
   - Reaches food and starts eating animation
3. Food walk behavior is identical to pre-fix behavior
4. No physics-related issues during food walk

**Failure Indicators:**
- Cat doesn't respond to food
- Food walk animation is broken
- Cat jumps during food walk (incorrect behavior)
- App crashes when food appears

---

### Scenario 7: Physics Dynamics Verification

**Pre-conditions:**
- App is running
- No cats on screen

**Test Steps:**
```bash
# Create multiple cats
send_event "physics-test-1" "session_start"
send_event "physics-test-2" "session_start"
sleep 0.5

# Cycle through various states
send_event "physics-test-1" "tool_start" "Edit"
sleep 1.0
send_event "physics-test-1" "idle"
sleep 0.5
send_event "physics-test-1" "tool_start" "Write"
sleep 1.0
send_event "physics-test-1" "session_end"
sleep 0.5

send_event "physics-test-2" "session_end"
```

**Expected Observable Outcome:**
1. All state transitions execute smoothly
2. Physics `isDynamic` is properly managed:
   - `false` during jumps (both random walk and exit)
   - `true` in all other states
   - Restored immediately after jump completes
3. Cats can be interacted with normally in all non-jump states
4. No "stuck" physics bodies (cats that can't be moved)

**Failure Indicators:**
- Cats become unmovable after certain state changes
- Cats fall through ground (physics disabled too long)
- Visual jitter or physics glitches
- App crashes during state transitions

---

### Scenario 8: Stress Test - Rapid State Changes

**Pre-conditions:**
- App is running
- No cats on screen

**Test Steps:**
```bash
# Create 3 cats
for i in 1 2 3; do
    send_event "stress-$i" "session_start"
done
sleep 0.5

# Rapid cycling
for i in 1 2 3; do
    send_event "stress-$i" "tool_start" "Edit"
done
sleep 0.3

for i in 1 2 3; do
    send_event "stress-$i" "idle"
done
sleep 0.2

for i in 1 2 3; do
    send_event "stress-$i" "tool_start" "Write"
done
sleep 0.3

for i in 1 2 3; do
    send_event "stress-$i" "session_end"
done
```

**Expected Observable Outcome:**
1. All events accepted without errors
2. App remains stable throughout rapid cycling
3. Cats transition smoothly between states
4. No stuck animations or incomplete state transitions
5. No memory leaks (memory usage stable after cycling)
6. No action buildup (old actions properly cancelled)

**Failure Indicators:**
- App crashes or freezes
- Cats show wrong animation for their state
- Multiple animations playing simultaneously
- Memory usage grows unbounded
- Console shows errors about stuck actions

---

## Visual Verification Checklist

For each scenario, verify:

- [ ] Cats display name labels (debug- prefix)
- [ ] Jump arc is smooth and follows expected path
- [ ] Jump animation frames play correctly
- [ ] Cat lands at ground level (no floating or sinking)
- [ ] Physics doesn't cause jitter during jump
- [ ] Random walk continues normally after jump
- [ ] State transitions are clean and instantaneous
- [ ] No visual artifacts or glitches
- [ ] FPS remains stable (no stuttering)
- [ ] Console shows no errors or warnings

---

## Common Failure Patterns

### Physics-Related Issues
- Cats get stuck in walls or each other
- Cats fall through the floor
- Cats bounce or jitter when they shouldn't
- Collision detection triggers during jumps

### Animation-Related Issues
- Wrong animation plays for current state
- Animation stops mid-cycle
- Multiple animations overlap
- Jump animation doesn't play

### State Machine Issues
- State doesn't change when expected
- Old state persists visually
- State cleanup doesn't run
- Actions from previous state continue

### Memory/Performance Issues
- FPS drops over time
- Memory usage grows unbounded
- Actions accumulate without cleanup
- Console shows warnings about action counts

---

## Testing Tools

### Socket Monitoring
```bash
# Monitor socket activity (helpful for debugging)
socat -u UNIX-CONNECT:/tmp/claude-buddy.sock -
```

### Debug Cat Labels
All cats with `debug-` prefix in their session_id will permanently show their name labels. Use this to identify cats during manual testing.

### Screen Recording
Record the test session to verify jump animations and detect subtle issues:
```bash
# macOS screen recording
screenrecord /tmp/test-recording.mp4
```

---

## Automated vs Manual Testing

### Automated Tests (test-random-walk-jumps.acceptance.sh)
- Verify app stability
- Test state transitions
- Ensure no crashes
- Check socket communication
- **Cannot verify visual behavior**

### Manual Tests (this guide)
- Verify jump animations look correct
- Confirm physics behavior
- Detect visual glitches
- Observe timing and smoothness
- **Essential for complete validation**

---

## Passing Criteria

The bug fix is considered successful when:

1. **All automated tests pass** (no crashes, stable state transitions)
2. **All manual test scenarios pass** (visual verification)
3. **No regressions** in existing exit jump behavior
4. **No regressions** in food walk behavior
5. **Performance is maintained** (no FPS drops, memory stable)

---

## Known Limitations

1. **Random walk is non-deterministic**: The exact path and timing of jumps varies each run. This is expected behavior.

2. **Manual testing required**: Automated tests can't verify visual correctness. Human observation is essential.

3. **Race conditions possible**: Rare edge cases with rapid state changes may require additional investigation if issues arise.

4. **Scene size dependent**: Jump behavior may vary slightly depending on scene width and cat spawn positions.

---

## Troubleshooting

### App Won't Start
```bash
# Check for existing socket
ls -la /tmp/claude-buddy.sock

# Kill any existing instance
pkill ClaudeCodeBuddy

# Rebuild
make clean && make build
```

### Socket Connection Errors
```bash
# Verify socket exists
test -S /tmp/claude-buddy.sock && echo "Socket exists" || echo "No socket"

# Check app is running
ps aux | grep ClaudeCodeBuddy
```

### Cats Not Appearing
- Check console for errors
- Verify session events are being sent
- Check that session_id doesn't conflict with existing cats
- Ensure maxCats limit (8) not exceeded

### Jump Not Executing
- Verify cats are in toolUse state
- Check that obstacles are within detection range (±24px tolerance)
- Ensure scene width is set correctly
- Verify physics body exists on containerNode

### Physics Glitches
- Check that `isDynamic` is properly toggled
- Verify physics body size matches constants (44x44)
- Check for overlapping collision bitmasks
- Ensure gravity is applied correctly

---

## References

- Bug Description: See test script header for original bug report
- Fix Location: `Sources/ClaudeCodeBuddy/Entity/Components/MovementComponent.swift`
- Constants: `Sources/ClaudeCodeBuddy/Entity/Cat/CatConstants.swift`
- Physics Setup: `Sources/ClaudeCodeBuddy/Entity/Cat/CatEntity.swift` (setupPhysicsBody)
