# NPC Retreat & Recovery System — Design Spec (Final)

## Overview

Replace the current "fight to the death" behavior with a health-threshold-triggered retreat system. NPCs that take enough damage while being attacked disengage combat, walk to the safest available adjacent friendly tile (invulnerable during transit), then enter a vulnerable recovery state (skull GUI visible) until healed past a recovery threshold.

---

## Architecture: Hybrid Combat-Loop-Driven (Approach A)

Add a `Combat.tryTriggerRetreat(npcModel)` helper called inside the existing combat loop (after humanoid/health validation, before attack execution for that tick). This keeps the loop readable while centralizing all retreat decision logic in one function.

The combat system **owns** retreat decisions. The movement system **owns** pathing. They coordinate via an `OnRetreatArrived(npcModel)` callback.

---

## Thresholds (Constants, Tunable)

| Constant | Example Value | Purpose |
|----------|--------------|---------|
| `RETREAT_THRESHOLD` | 0.30 | Health ratio below which retreat triggers |
| `RECOVERY_THRESHOLD` | 0.55 | Health ratio above which recovery clears (skull removed, can attack again) |
| `RETREAT_RETRY_COOLDOWN` | 3–5 seconds | Prevents re-checking retreat every 0.1s tick after a failed attempt |

Single hysteresis pair. No intermediate "re-engage" threshold — the `RECOVERING` state itself is the gameplay lock that prevents attacking until `RECOVERY_THRESHOLD` is crossed.

---

## Unified State Attribute

**`RetreatState`: `"None"` | `"Retreating"` | `"Recovering"`** — set on the NPC model as an attribute.

- This is the **authoritative gameplay state** for retreat/recovery logic, attack blocking, skull GUI, and vulnerability.
- `NPCMovementSystem` maintains its own internal `movementStates[npc].state` for pathing independently.
- Both systems coordinate via the `OnRetreatArrived(npcModel)` callback but do not overwrite each other's domain.

---

## State Machine

```
"None" ──(health < RETREAT_THRESHOLD while being attacked)──> Combat.tryTriggerRetreat()
    → Selects retreat tile (see Tile Selection section)
    → ONLY on successful movement start:
        → Combat.disengageForRetreat(npc)
        → Set RetreatState = "Retreating"
        → NPC walks to tile (invulnerable, NO regen during walk)

"Retreating" ──(arrival at retreat tile)──> Movement fires OnRetreatArrived(npc)
    → Set RetreatState = "Recovering"
    → Enable Health script (regen starts NOW, after arrival)
    → Show skull BillboardGui (already exists in NPC templates — toggle Enabled = true)
    → Connect Humanoid.HealthChanged listener

"Recovering" ──(HealthChanged: health/maxHealth > RECOVERY_THRESHOLD)──>
    → Set RetreatState = "None"
    → Hide skull GUI (Enabled = false)
    → Disconnect HealthChanged listener
    → NPC fully operational

"Recovering" ──(killed by enemy)──> normal death cleanup
```

---

## Vulnerability Rules

| State | Can Be Attacked | Can Attack / Auto-Retaliate | Can Receive Move Orders |
|-------|-----------------|----------------------------|------------------------|
| None | Yes | Yes | Yes |
| Retreating | **No** (invulnerable) | No | No |
| Recovering | **Yes** (killable) | **No** | **Yes** |

---

## Retreat Eligibility (Trigger Conditions)

Retreat triggers only when **ALL** are true:

1. NPC is alive (`humanoid.Health > 0`)
2. `RetreatState == "None"` (not already retreating/recovering)
3. `humanoid.Health / humanoid.MaxHealth < RETREAT_THRESHOLD`
4. NPC is **being attacked** (not merely initiating):
   - Defender: `Combat.getAttackerCount(npc) > 0`
   - Attacker: `Combat.getThreatCount(npc) > 0`
5. Retreat retry cooldown has expired (if previously failed)
6. NPC is not in a non-retreat terminal transition

**Requirement #6 satisfied:** An Attacker that initiated combat against a Defender but has NO threats in `attackerThreats` will never trigger retreat, even at low health. The trigger requires being attacked, not merely having low health from initiating.

---

## Retreat Tile Selection Algorithm

### Candidate Generation
1. Get adjacent tiles via `TileAdjacencyManager.getAdjacentTiles(currentTilePart)`
2. **Filter to friendly-owned tiles only** — tiles belonging to the NPC's own country, or tiles conquered/occupied by the NPC's country. No allied or neutral territory. Friendly-owned tile checks must use **current tile ownership/control** (runtime game state), not the tile's original geographic country metadata from `TileAdjacencyManager.getTileCountry()`.

### Scoring
3. Find all enemy NPCs on tiles adjacent to the NPC's current tile (enemies = NPCs of countries at war with this NPC's country)
4. Score each candidate by **minimum distance to any enemy NPC position** (higher distance = safer)
5. **Fallback (no visible enemies):** Treat all valid candidates as equal. Choose by deterministic tie-break order (lowest tileId).

### Filtering
6. Remove tiles that are:
   - Already occupied by another NPC (`TileManager.isTileOccupiedById(tileId)`)
   - Already reserved by another retreating NPC (`reservedRetreatTiles[tileId] ~= nil`)

### Selection (Exhaustive)
7. Sort valid candidates by score descending (safest first)
8. Reserve best tile, attempt `NPCMovementSystem.startHealthRetreat(npc, tile)`
9. If movement start fails:
   - **Release reservation immediately**
   - Try next-best candidate
10. Continue until success or ALL candidates exhausted
11. **If ALL fail:** Retreat fails entirely. `disengageForRetreat()` is NOT applied. `RetreatState` remains `"None"`. NPC stays in combat. Set retry cooldown.

---

## Sequencing & Atomicity

Retreat is **transactional** — partial application is never left behind:

```
Combat.tryTriggerRetreat(npcModel):
    1. Check all preconditions (eligibility section above)
    2. Generate + filter + score retreat candidates
    3. If no candidates → return false, set cooldown
    4. For each candidate (best-first):
        a. Reserve tile (reservedRetreatTiles[tileId] = npcModel)
        b. Attempt NPCMovementSystem.startHealthRetreat(npc, tile)
        c. If success:
            → Combat.disengageForRetreat(npc)
            → npc:SetAttribute("RetreatState", "Retreating")
            → return true
        d. If fail:
            → Release reservation (reservedRetreatTiles[tileId] = nil)
            → Continue to next candidate
    5. All exhausted → return false, set cooldown, NPC stays in combat unchanged
```

**Critical:** `disengageForRetreat()` is ONLY called after movement start succeeds. If all candidates fail, combat state is completely untouched.

---

## Reservation System

**`reservedRetreatTiles[tileId] = npcModel`** — module-level table preventing two NPCs from retreating to the same tile.

### Reservation Release Triggers
| Event | Action |
|-------|--------|
| Successful arrival at retreat tile | Release reservation |
| Failed movement attempt | Release reservation immediately |
| NPC death / destruction | Release reservation |
| Movement cancellation | Release reservation |
| Ownership transfer / forced cleanup | Release reservation |

---

## Combat.disengageForRetreat(npcModel) — Full Cleanup

1. Clear this NPC's `manualTargets` list
2. Clear this NPC's own `defenderAttackers` / `attackerThreats` entries
3. Remove this NPC from **all other NPCs'**:
   - `manualTargets`
   - `defenderAttackers`
   - `attackerThreats`
4. Set `npcInCombat[npcModel] = false`
5. Stop any active beam/laser visuals for this NPC
6. Health script stays **disabled** during retreat walk (re-enabled only on arrival)

---

## Where Attack Commands Are Blocked (Recovering State)

| System | Check Location | Guard |
|--------|---------------|-------|
| `NPCTargetingHandler` | Second-click targeting (line ~170) | Reject if `RetreatState == "Recovering"` |
| `Combat.addManualTarget()` | Entry point | Return early if attacker `RetreatState == "Recovering"` |
| Combat loop (auto-retaliate) | Before threat/attacker processing | Skip retaliation if `RetreatState == "Recovering"` |

---

## Invulnerability (Retreating State)

Invulnerability is achieved by **target filtering**, not health manipulation:
- `NPCMovementSystem.canBeAttacked(npc)` already returns `not isRetreating(npc)`
- Add `isRetreating()` / `canBeAttacked()` checks in the two inline `getAllTargets` callbacks within `Combat.registerNPC()`:
  - Attacker callback (line ~614)
  - Defender callback (line ~685)

```lua
if NPCMovementSystem.isRetreating(target) then
    -- skip this target entirely
end
```

**Recovering NPCs are NOT invulnerable** — `canBeAttacked()` must return `true` for Recovering state. Only `Retreating` = invulnerable.

---

## Recovery Monitoring

**On entering RECOVERING state** (OnRetreatArrived callback):
1. Enable Health script (`setHealthScriptEnabled(npc, true)`) — regen begins
2. Toggle skull BillboardGui `Enabled = true` (GUI already exists in NPC templates)
3. Set `npc:SetAttribute("RetreatState", "Recovering")`
4. Connect `Humanoid.HealthChanged` listener for this NPC only

**HealthChanged handler:**
```lua
if humanoid.Health / humanoid.MaxHealth > RECOVERY_THRESHOLD then
    npc:SetAttribute("RetreatState", "None")
    skullGui.Enabled = false
    disconnect the listener
end
```

**Listener cleanup triggers:**
- Normal recovery (health crosses threshold)
- NPC death
- NPC destruction (`.Destroying`)
- Ownership transfer
- Any forced cleanup/reset

**Retreat retry cooldown cleanup:** Any retreat retry cooldown entry for the NPC must also be cleared on death, destruction, ownership transfer, or forced cleanup.

---

## Skull GUI

The skull `BillboardGui` already exists in both `AttackerNPC` and `DefenderNPC` templates in ReplicatedStorage. Implementation only needs to toggle `Enabled`:
- `Enabled = true` on entering RECOVERING
- `Enabled = false` on exiting RECOVERING (or death)

No new GUI creation needed — just show/hide the existing one.

---

## Applies To

- **Both AttackerNPCs and DefenderNPCs** retreat
- **Both player-owned and country-owned (AI/AutoRetaliate) NPCs** retreat
- The trigger condition differs by role:
  - Defender: retreat-eligible only if `Combat.getAttackerCount(npc) > 0`
  - Attacker: retreat-eligible only if `Combat.getThreatCount(npc) > 0`

---

## State Authority Clarification

| Domain | Authority | Notes |
|--------|-----------|-------|
| Retreat/recovery gameplay state | `RetreatState` attribute on NPC model | Authoritative for attack blocking, skull, vulnerability |
| Movement/pathing state | `NPCMovementSystem.movementStates[npc].state` | Internal to movement system |
| Combat engagement | `npcInCombat[npc]` in NPCCombatSystem | Cleared by `disengageForRetreat()` |

These never overwrite each other. They coordinate via callback (`OnRetreatArrived`) and API calls.

---

## Integration Points (File Locations)

| File | Changes |
|------|---------|
| `src/shared/NPCCombatSystem.luau` | Add `tryTriggerRetreat()`, `disengageForRetreat()`. Reuse existing `Combat.getAttackerCount()` and `Combat.getThreatCount()` (do not re-add). Call `tryTriggerRetreat()` in combat loop (after health validation, before attack execution). Handle `OnRetreatArrived` callback (set Recovering state, enable regen, show skull, attach HealthChanged listener). Block auto-retaliate for Recovering NPCs. Add retreat cooldown tracking. Add `reservedRetreatTiles` table. |
| `src/shared/NPCMovementSystem.luau` | Add `startHealthRetreat(npc, tilePart)` function (similar to existing movement but sets internal state to "Retreating" for invulnerability). Fire `OnRetreatArrived(npcModel)` callback on arrival. Ensure `canBeAttacked()` returns `true` for Recovering NPCs (only Retreating = invulnerable). |
| `src/server/NPCTargetingHandler.server.luau` | Guard second-click targeting against `RetreatState == "Recovering"`. |
| `src/server/NPCSpawner.luau` | Initialize `RetreatState = "None"` attribute on spawn. Add reservation release + HealthChanged listener disconnect to death/destroy cleanup. |
| `src/shared/TileManager.luau` | No changes (existing occupancy API suffices). |
| `src/shared/TileAdjacencyManager.luau` | No changes (existing adjacency query API suffices). |

---

## API Surface Used / Added

### In NPCCombatSystem:
```lua
Combat.tryTriggerRetreat(npcModel) → boolean   -- NEW
Combat.disengageForRetreat(npcModel) → void    -- NEW
Combat.getAttackerCount(npcModel) → number     -- EXISTING (reuse as-is)
Combat.getThreatCount(npcModel) → number       -- EXISTING (reuse as-is)
```

### In NPCMovementSystem:
```lua
NPCMovementSystem.startHealthRetreat(npcModel, targetTilePart) → (boolean, string?)
-- Returns (success, errorMsg). Sets internal state to "Retreating".
-- On arrival: fires OnRetreatArrived callback, updates tile occupancy.
```

---

## Constants Summary

```lua
local RETREAT_THRESHOLD = 0.30        -- health ratio to trigger retreat
local RECOVERY_THRESHOLD = 0.55       -- health ratio to clear recovery
local RETREAT_RETRY_COOLDOWN = 4.0    -- seconds before retreat can re-attempt after failure
```

These are placeholder values — tune based on playtesting.

---

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| NPC at low health initiates attack (Attacker, no threats) | Does NOT retreat (requirement #6) |
| Two NPCs try to retreat to same tile simultaneously | Reservation system prevents — second NPC picks next-best tile |
| All adjacent friendly tiles occupied/reserved | Retreat fails, NPC stays in combat, cooldown set |
| NPC killed during Recovering state | Normal death cleanup (release reservation, disconnect listener, hide skull) |
| NPC ownership transferred during Recovering | Clear RetreatState to "None", disconnect listener, hide skull, release reservation |
| NPC retreating when owner leaves game | Movement completes, enters Recovering normally under new country-owned state |
| No enemy NPCs visible for scoring | All valid candidates scored equally, picked by deterministic tie-break (lowest tileId) |
| Enemy attacks Recovering NPC | Allowed — NPC is killable but cannot fight back |
| Retreat destination becomes occupied during transit | If the reserved retreat destination becomes invalid during transit (e.g. occupied by another NPC), v1 uses the existing movement fallback: the NPC returns to its origin tile and still enters Recovering there. This is an intentional simplification for v1, not a second retreat-candidate search mid-transit. |

---

## Existing Codebase Context (for implementer)

### NPCCombatSystem (`src/shared/NPCCombatSystem.luau`, 927 lines)
- Combat loop: lines 304–369, runs at `LOOP_WAIT = 0.1s`
- `DAMAGE = 10` per shot, split among targets
- `fireMultiLaser()`: line ~238, deals damage
- `npcInCombat[npcModel]`: boolean combat state
- `manualTargets[npcModel]`: attacker's target list
- `defenderAttackers[defenderModel]`: who's attacking a defender
- `attackerThreats[attackerModel]`: who's counter-attacking an attacker
- `Combat.clearAllManualTargets()`: clears targets + reciprocal refs
- Health script control: `setHealthScriptEnabled(npc, bool)` (line 146–155)
- Death cleanup: `humanoid.Died:Once(...)` (line 134–143)

### NPCMovementSystem (`src/shared/NPCMovementSystem.luau`, 2131 lines)
- States: `"Idle" | "Moving" | "Retreating"`
- `isRetreating(npc)`: line 1198–1200
- `canBeAttacked(npc)`: line 1210–1212, returns `not isRetreating(npc)`
- Existing `startRetreat()`: line 1987–2036, snaps back to origin (NOT suitable for forward retreat)
- `startMovement()`: line 1699–1981, moves to adjacent tile
- Health script disabled during movement (line 1928)
- Arrival detection: heartbeat at 0.1s intervals

### TileAdjacencyManager (`src/shared/TileAdjacencyManager.luau`, 1800+ lines)
- `getAdjacentTiles(tilePart)`: returns neighbor list
- `canNPCsInteract(npcA, npcB)`: adjacency check for combat
- `getTileId(tilePart)`: get stable TileId
- `getTileCountry(tilePart)`: get geographic country from hierarchy

### TileManager (`src/shared/TileManager.luau`, 561 lines)
- `GlobalOccupiedTilesById[tileId]`: authoritative occupancy
- `isTileOccupiedById(tileId)`: check occupancy
- `getTileOccupantById(tileId)`: get NPC at tile
- `occupyTileById(tileId, npcModel)` / `releaseTileById(tileId)`: write occupancy

### NPCSpawner (`src/server/NPCSpawner.luau`, 170 lines)
- Sets attributes: `TileKey`, `Country`, `CurrentTileId`, `AutoRetaliate`
- Cleanup pipeline: lines 106–155 (death + destroying handlers)
- Skull BillboardGui already exists in templates (just needs `Enabled` toggle)

### NPC Attributes (already set on spawn)
- `TileKey`: string "x,z"
- `Country`: string
- `CurrentTileId`: string (stable TileId)
- `IsMoving`: boolean
- `AutoRetaliate`: boolean (country-owned only)
- **NEW:** `RetreatState`: "None" | "Retreating" | "Recovering"

---

## Explicit Non-Goals for v1

- Exhaustion counter (retreat limit)
- Player-controlled retreat button
- Chain-retreat during transit
- Different thresholds per NPC type
- Retreat sound/VFX beyond skull GUI
- Allied territory as valid retreat destination
