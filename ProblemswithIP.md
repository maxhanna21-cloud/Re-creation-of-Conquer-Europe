# Gap Analysis: ImplementationPlan.MD

> **Last updated:** 2026-05-06 — verified against both `src/` Luau files and live Roblox Studio state via MCP.

---

## CRITICAL — Will cause visible failure

### 1. Forward reference bug — `handleRetreatArrival` referenced before declaration

Task 4, Step 2 wires the callback at line ~42 (inside the `getNPCMovementSystem` lazy loader):

```lua
NPCMovementSystem.OnRetreatArrived = handleRetreatArrival
```

But `handleRetreatArrival` is a `local function` declared near line ~900 (Task 4, Step 1). In Luau, a local variable is only visible from the statement after its declaration to the end of the enclosing block. The closure at line 42 resolves `handleRetreatArrival` as a **global lookup** (not an upvalue), and since no global by that name exists, it evaluates to `nil` at call time. The callback never fires. NPCs walk to their retreat tile, arrive, and nothing happens — no Recovering state, no skull, no regen.

**Fix:** Add a forward declaration at the top of the file (near the retreat data tables in Task 1, Step 4):

```lua
local handleRetreatArrival  -- forward declaration; body assigned in Task 4
```

Then in Task 4, Step 1, change `local function handleRetreatArrival(npcModel)` to `handleRetreatArrival = function(npcModel)`.

---

### 2. Player-owned Defenders can never retreat

Task 7, Step 2b moves **Attacker** threat tracking above the `AutoRetaliate` guard so player-owned Attackers can retreat. But it leaves **Defender** attacker tracking (`noteAttackerTargeting`) below the guard:

```lua
-- Attacker tracking: moved above guard ✓
if targetRole == "Attacker" then
    Combat.noteTargetingAttacker(attackerNpc, targetNpc)
end

-- Guard: player-owned NPCs return here
if targetNpc:GetAttribute("AutoRetaliate") ~= true then return end

-- Defender tracking: still below guard ✗
if targetRole == "Defender" then
    Combat.noteAttackerTargeting(attackerNpc, targetNpc)
end
```

Since player-owned Defenders have `AutoRetaliate ~= true`, `noteHit` returns early before `noteAttackerTargeting` fires. Their `defenderAttackers` table is never populated. Then in `tryTriggerRetreat`, the Defender path checks `Combat.getAttackerCount(npcModel) <= 0` — always 0 for player-owned Defenders — so retreat never triggers. They fight to the death.

**Fix:** Move `noteAttackerTargeting` for Defenders above the `AutoRetaliate` guard (same treatment as the Attacker path), or explicitly document that player-owned Defenders are intended to never retreat and add a comment in `tryTriggerRetreat` explaining this design choice.

---

## HIGH — Causes incorrect behavior in edge cases

### 3. Ownership transfer during active health retreat leaves movement/gameplay state desynchronized

`Combat.transferOwnership()` calls `cleanupRetreatState()`, which clears `RetreatState` and releases the retreat reservation. However, the active movement in `NPCMovementSystem` may continue because `OnOwnerChanged()` returns early when `movementStates[npc].state == "Retreating"`.

This creates a desync:

1. Ownership transfer fires.
2. `cleanupRetreatState()` sets `RetreatState = "None"` and releases combat-side retreat state.
3. `OnOwnerChanged()` sees movement state `"Retreating"` and returns early.
4. The NPC continues walking as a health retreat even though gameplay retreat state is cleared.
5. On arrival, `monitorMovement()` performs tile occupancy transfer, but `handleRetreatArrival()` returns early because `RetreatState ~= "Retreating"`.
6. The NPC will not enter Recovering, will not show skull, and may retain stale health-retreat metadata such as `isHealthRetreat` (see sub-issue below).

**Sub-issue — `isHealthRetreat` unreachable cleanup:** Task 8, Step 5 adds `movementStates[npcModel].isHealthRetreat = nil` to `OnOwnerChanged` at line ~2063, but the early return at line 2058 (for `"Moving"` or `"Retreating"`) prevents it from ever executing during an active health retreat. The flag persists indefinitely.

**Fix:** Add an explicit health-retreat cancellation path in `NPCMovementSystem`, such as `cancelHealthRetreat(npcModel)`, and call it from `Combat.transferOwnership()` or from `Combat.cleanupRetreatState()` via the existing lazy-loaded movement-system accessor. This function should cancel the in-flight movement, clear `isHealthRetreat`, and release any movement-side state. Also update `OnOwnerChanged()` to handle `movementStates[npc].isHealthRetreat` before the generic `"Retreating"` early return.

---

### 4. `disengageForRetreat` redundantly removes NPC from others' tracking lists

`clearAllManualTargets` (called in step 1 of `disengageForRetreat`) already performs reciprocal cleanup in the current implementation — it removes the NPC from other NPCs' `defenderAttackers` entries. Then step 3 manually iterates `manualTargets`, `defenderAttackers`, and `attackerThreats` for ALL other NPCs again. This is harmless today, but:

- It's O(N * M) redundant work on every retreat
- If `clearAllManualTargets` implementation changes, the second pass silently becomes the only cleanup, masking the regression

**Fix:** Either remove the redundant manual loops and rely on `clearAllManualTargets`'s reciprocal cleanup, or remove the `clearAllManualTargets` call and keep only the explicit loops. Don't do both.

---

## MEDIUM — Plan is ambiguous or drift-prone

### 5. Line numbers are consistently off by 1-3 lines

The plan references specific line numbers that don't match the actual file state:

| Plan says | Actual |
|-----------|--------|
| `return Combat` at line 932 | line 931 |
| `addManualTarget` at line 461 | line 459 |
| `noteHit` at line 824 | line 822 |
| `unregisterNPC` at line 720 | line 719 |

Every "insert after line X" instruction is subtly wrong. An agentic worker following line numbers literally will insert code in the wrong place.

**Fix:** Reference anchor patterns (function names, comments, unique code strings) instead of line numbers, or correct all line numbers before implementation.

---

### 6. Inconsistent health-script function names across modules

`startHealthRetreat` (MovementSystem) calls `setNPCHealthScriptEnabled(npcModel, false)`. `handleRetreatArrival` (CombatSystem) calls `setHealthScriptEnabled(npcModel, true)`. These are different `local` functions in different modules. Both find and toggle `npcModel:FindFirstChild("Health", true).Enabled`, so they're functionally identical today. But if one diverges (adds guards, side effects, or logging), the retreat flow would have asymmetric enable/disable behavior.

**Fix:** Note in the plan that this is intentional (each module owns its own health-script helper), or refactor to call a single canonical path (e.g., always go through the CombatSystem's version since it owns combat state).

---

## LOW — Correctness nits

### 7. `tryTriggerRetreat` enemy scoring only considers current-tile adjacency

The safety score computes "distance from enemies on tiles adjacent to the **current** tile." But the NPC is moving **away**. A candidate that's far from current-tile enemies might be adjacent to enemies on tiles the scoring doesn't check. A more robust heuristic would score enemies adjacent to each **candidate** tile.

This is a design-quality issue, not a correctness bug — the NPC still retreats to a valid friendly tile.

---

### 8. No guard against retreat during `Retreating` movement state desync

`tryTriggerRetreat` checks `RetreatState ~= "None"` (attribute) but not `movementStates[npc].state`. If somehow `RetreatState` is `"None"` but the movement-level state is `"Retreating"` (a desync), the NPC could start a second retreat. The plan says the two states are independent, but doesn't account for desync.

---

### 9. Verification checklist scenario 3 ("Attacker halt") is implicit, not explicit

The "halt" behavior (attacker at low health with no threats clears targets and stops) works correctly through `tryTriggerRetreat` returning `false` → combat loop finding no targets → idle. But it's an emergent behavior, not an explicit implementation. Worth a comment in the plan so a future reader understands the flow.

---

## FALSE POSITIVES — Verified not issues

These were initially flagged but confirmed valid after checking Roblox Studio via MCP:

| # | Original claim | Why it's fine |
|---|---------------|---------------|
| ~~SkullGui missing~~ | `SkullGui` exists as a Studio-authored `BillboardGui` on both `ReplicatedStorage.AttackerNPC.Head.SkullGui` and `ReplicatedStorage.DefenderNPC.Head.SkullGui`. Disabled by default, with `SkullHead` and `Jaw` frame children. Not in `.lua` source because it's an instance, not code. |
| ~~Instant death bypasses Died~~ | `humanoid.Health = 0` correctly triggers `Humanoid.Died`, which fires `cleanup` via `humanoid.Died:Once(cleanup)` in NPCSpawner (line 181). Standard Roblox death flow. |
| ~~Conquest chain resolution~~ | NPC `Country` attribute is always a clean country name (set at NPCSpawner line 115). `tileEffectivelyBelongsTo` compares clean names at the tile level — conquest chains (`"Conquered_X"`) exist only in `ServerState` country ownership, not on tile attributes or NPC attributes. |
| ~~retreatCallbackFired double-fire~~ | `stopMovement` disconnects the Heartbeat connection synchronously (line 1247) before `activeMovements[npcModel]` is cleared (line 1249). No re-entry is possible. The `retreatCallbackFired` flag is safe defense-in-depth. |

---

## Summary

**2 critical gaps** (#1 forward reference, #2 player-owned Defender retreat) will cause direct implementation failures — retreat arrival callback silently never fires, and a class of NPCs can never retreat.

**2 high gaps** (#3 ownership transfer desync + unreachable cleanup, #4 redundant disengagement) will cause state desync bugs or maintenance hazards in edge cases.

**2 medium gaps** (#5 line number drift, #6 inconsistent function names) can cause misplaced insertions or future divergence.

**3 low nits** (#7 scoring heuristic, #8 movement-state desync guard, #9 implicit attacker halt) should be addressed or documented for robustness.

All critical and high gaps must be addressed before handing the plan to an agentic worker.
