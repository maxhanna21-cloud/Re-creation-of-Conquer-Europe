# Brainstorm Findings Reconciled
**NPC Combat Retreat System — Reconciliation Pass**

---

## 1. Contradictions Found

| Contradiction | Why It's a Problem | Corrected Rule |
|---------------|-------------------|----------------|
| Document says "Use or extend startRetreat() for combat retreat" but `startRetreat(npcModel, originTileKey, originPosition)` is designed specifically for snap-back to origin tile, not forward movement to a new destination | `startRetreat` sets `targetTileKey = originTileKey` and moves TO the origin. Combat retreat must move AWAY from origin to a safer adjacent tile. These are opposite operations. | **Corrected:** Must create new `startCombatRetreat(npcModel, targetTileKey, targetTilePart)` function that moves NPC to a chosen destination tile (not origin). Cannot reuse existing `startRetreat()` - it's the wrong semantic. |
| Document says "Add isRetreating() check in getAllTargets()" as if getAllTargets is a module function | `getAllTargets` is NOT a module function. It's an inline anonymous function passed as a callback to `startCombatLoop()` at lines 595 and 673. | **Corrected:** Must add `NPCMovementSystem.isRetreating(target)` check inside the two inline `getAllTargets` callbacks within `Combat.registerNPC()` — one for Attackers (line ~614), one for Defenders (line ~685). |
| Document says "Intercept damage in fireMultiLaser() before TakeDamage()" but also says "If no valid tile: return false, deal damage, NPC dies" | If we intercept BEFORE TakeDamage, we need to conditionally apply the damage ourselves when retreat fails. The current wording is ambiguous about who applies damage on retreat failure. | **Corrected:** The interception point checks `if damage would drop health ≤ threshold`. If retreat succeeds, skip TakeDamage entirely. If retreat fails OR skull is active, call TakeDamage normally. The interception wrapper applies damage on failure, not the caller. |
| Document lists "retreatReservations" as a new table but also references "releaseTileReservation" from movement system | The existing `releaseTileReservation` is a private function inside NPCMovementSystem. It operates on `reservedTiles`, not on `retreatReservations`. These are two different reservation systems. | **Corrected:** Combat retreat uses its own `retreatReservations` table in NPCRetreatSystem. This is separate from NPCMovementSystem's `reservedTiles`. When retreat movement starts, occupancy is managed via `TileManager.occupyTileById/releaseTileById`, not via movement reservations. |

---

## 2. Unsupported or Assumed APIs

| Referenced API | Actually Provided? | Correction |
|----------------|-------------------|------------|
| `DiplomacyManager.areCountriesAllied(countryA, countryB)` | **YES** — line 54 of DiplomacyManager.luau | No correction needed. API exists. |
| `DiplomacyManager.areCountriesAtWar(countryA, countryB)` | **YES** — line 46 of DiplomacyManager.luau | No correction needed. API exists. |
| `TileManager.occupyTileById(tileId, npcModel)` | **YES** — line 342 of TileManager.luau | No correction needed. API exists. |
| `TileManager.releaseTileById(tileId)` | **YES** — line 348 of TileManager.luau | No correction needed. API exists. |
| `NPCMovementSystem.canBeAttacked(npcModel)` | **YES** — line 1210 of NPCMovementSystem.luau. Returns `not isRetreating(npcModel)` | Exists but **NOT CALLED** by NPCCombatSystem. Combat target filtering does not use this function. Must add calls to inline getAllTargets callbacks. |
| `startCombatRetreat(npcModel, targetTileKey, targetTilePart)` | **NO** — does not exist | **New API to add.** Must be created in NPCMovementSystem. Similar to `startMovement` but sets state to "Retreating" for invulnerability. |
| `getAllTargets()` as a module function | **NO** — getAllTargets is an inline anonymous function, not a module API | **Remove dependency.** The filtering must be added inside the two inline callbacks at lines 595-626 and 673-696 in NPCCombatSystem.luau. |

---

## 3. Rules That Need Exact Final Wording

### Retreat Trigger Rule
When `fireMultiLaser()` is about to call `targetHumanoid:TakeDamage(damagePerTarget)`, first check: would `(humanoid.Health - damagePerTarget) / humanoid.MaxHealth <= RETREAT_HEALTH_THRESHOLD`? If yes, call `NPCRetreatSystem.attemptRetreat(targetNpcModel)`. If attempt returns true, skip TakeDamage for this target. If attempt returns false, call TakeDamage normally.

### Damage Interception Rule
Interception happens inside `fireMultiLaser()` at line 238, wrapping the `TakeDamage` call. The wrapper calculates projected health percentage. If projected health ≤ 10% AND no skull, attempt retreat. On success, skip damage. On failure (no valid tile or skull active), apply damage.

### Post-Retreat Health Rule
Successful retreat does NOT modify health. The NPC survives at its current health (which is ≤ 10% of max). Natural health regeneration must bring health above 30% to remove the skull.

### Skull Behavior Rule
After successful retreat: set `hasSkull[npcModel] = true`, show skull BillboardGui, connect `Humanoid.HealthChanged`. While skull is active, retreat is blocked — any damage that would trigger retreat instead kills the NPC. When `health / maxHealth >= SKULL_REMOVAL_THRESHOLD`, remove skull, disconnect HealthChanged connection, and retreat becomes available again.

### Invulnerability Rule
Invulnerability is achieved by target filtering, not health manipulation. When `movementStates[npc].state == "Retreating"`, the NPC must be excluded from all combat target lists. Add check `if NPCMovementSystem.isRetreating(target) then skip` in both inline getAllTargets callbacks (Attacker at line ~614, Defender at line ~685).

### Valid Destination Territory Rule
Valid retreat destinations must satisfy: `TileManager.getTileOccupantById(tileId) == nil` (not occupied) AND `retreatReservations[tileId] == nil` (not reserved by another retreating NPC) AND one of: (a) `TileAdjacencyManager.getEffectiveOwner(tile) == npcCountry`, OR (b) `DiplomacyManager.areCountriesAllied(npcCountry, tileOwner)`, OR (c) tile's `OwnerCountry` attribute == npcCountry (conquered territory). Tiles controlled by enemies are invalid.

### No-Capture Rule
Retreat movement does NOT trigger `TileOwnershipManager` capture logic. When the NPC arrives at the destination tile, update occupancy via `TileManager.occupyTileById(newTileId, npcModel)` and `TileManager.releaseTileById(oldTileId)`, but do NOT call any capture/takeover functions.

### Movement-Failure Retry Rule
If `startCombatRetreat()` returns false for the best-scored tile, release its reservation from `retreatReservations`, try the next-best tile. Repeat until success or no valid tiles remain. If all tiles fail, `attemptRetreat()` returns false and damage is applied.

### Transit Edge-Case Rule
If the retreat destination becomes occupied while the NPC is in transit, use existing `startRetreat()` to snap back to origin tile. NPC ends up at origin with skull active. Next lethal damage kills the NPC (skull blocks retreat).

### Cleanup Rule
On `Humanoid.Died` or `Model.Destroying`: clear `hasSkull[npcModel]`, release any entry in `retreatReservations` where value == npcModel, disconnect and nil `healthChangedConnections[npcModel]`. Hook into existing maid cleanup in `Combat.registerNPC()` or add parallel cleanup in NPCRetreatSystem.

---

## 4. Corrected Decision Table

| Decision | Final Wording for Draft Use | Confidence |
|----------|----------------------------|------------|
| Retreat threshold | `RETREAT_HEALTH_THRESHOLD = 0.10` — retreat triggers when projected health would drop to ≤ 10% | Settled |
| Skull removal threshold | `SKULL_REMOVAL_THRESHOLD = 0.30` — skull removed when health regenerates to ≥ 30% | Settled |
| Automatic retreat only | No player input; retreat triggers automatically server-side | Settled |
| Distance scoring | `(tilePos - enemyPos).Magnitude` for each enemy within scan radius; tile score = minimum distance to any enemy; pick tile with highest score | Settled |
| Enemy scan radius | `ENEMY_SCAN_RADIUS = 100` studs; only consider enemies within this radius for scoring | Provisional |
| No capture during retreat | Retreat arrival updates occupancy only, no ownership transfer | Settled |
| Territory validity | Same-country OR allied OR conquered-by-NPC's-country. No enemy tiles. | Settled |
| Tie-breaker priority | Same-country > allied > conquered > neutral (if neutral is ever valid) | Provisional |
| Die if no valid tile | `attemptRetreat()` returns false; damage is applied; NPC dies | Settled |
| Health unchanged after retreat | NPC keeps current health; must regenerate above 30% | Settled |
| Skull GUI | BillboardGui with skull ImageLabel visible to all players | Settled |
| Skull asset | Use placeholder ImageId; finalize during implementation | Provisional |
| Invulnerability mechanism | Filter retreating NPCs from target lists via `isRetreating()` check | Settled |
| New startCombatRetreat function | Required in NPCMovementSystem; cannot reuse existing startRetreat | Settled |
| Separate retreatReservations | New table in NPCRetreatSystem; separate from movement reservations | Settled |
| Intercept point | Inside `fireMultiLaser()` at line 238, wrapping TakeDamage | Settled |
| Target filtering location | Inside inline getAllTargets callbacks at lines ~614 and ~685 | Settled |
| Exhaustion counter | Future enhancement; design API to support later | Settled |

---

## 5. Corrected Rules Matrix

| Condition | Expected Behavior |
|-----------|-------------------|
| Damage would drop health to ≤10% | Check skull: if no skull → attemptRetreat(); if skull active → apply damage, NPC dies |
| attemptRetreat() called, no skull | Get adjacent tiles, filter valid, score by enemy distance, try best tile first |
| Best tile reservation succeeds | Call startCombatRetreat(), set hasSkull, show GUI, connect HealthChanged, return true |
| Best tile reservation fails | Release, try next tile; repeat until success or exhausted |
| All tiles invalid/fail | Return false; caller applies damage; NPC dies |
| Tile is enemy-controlled | Invalid destination; skip during evaluation |
| Tile is same-country | Valid; highest priority tie-breaker |
| Tile is allied | Valid; second priority tie-breaker |
| Tile is conquered (OwnerCountry == npcCountry) | Valid; third priority tie-breaker |
| Retreat destination occupied | startCombatRetreat returns false; try next tile |
| Destination becomes occupied during transit | Existing startRetreat() snaps NPC to origin; skull remains; next lethal hit kills |
| NPC state == "Retreating" | Invulnerable; excluded from all combat target lists |
| Health regenerates to ≥30% | Skull removed; hasSkull cleared; HealthChanged disconnected; retreat available |
| Lethal damage while skull active | Retreat blocked; damage applied; NPC dies |
| NPC dies during retreat (TileOwnershipManager) | Death proceeds; cleanup clears hasSkull, reservations, connections |
| Retreat completes successfully | Update occupancy via TileManager; state → Idle; skull persists until 30% |

---

## 6. Safe Assumptions for the First Draft

1. `DiplomacyManager.areCountriesAllied()` and `areCountriesAtWar()` work correctly for all country pairs.
2. `TileManager.occupyTileById()` and `releaseTileById()` correctly update `GlobalOccupiedTilesById`.
3. `TileAdjacencyManager.getAdjacentTiles()` returns only walkable adjacent tiles.
4. `NPCMovementSystem.isRetreating()` returns true when state == "Retreating".
5. Humanoid.HealthChanged fires reliably during health regeneration.
6. BillboardGui attached to NPC with Adornee set will render for all players.
7. The existing maid pattern in Combat.registerNPC() can accommodate additional cleanup callbacks.
8. `fireMultiLaser()` is the only damage source for NPC-vs-NPC combat (no environmental damage in v1).

---

## 7. Items That Must Be Marked Provisional in the First Draft

1. **Enemy scan radius (100 studs)** — may need tuning based on map scale and combat feel
2. **Tie-breaker priority order** — same-country > allied > conquered is a reasonable guess; may need balancing
3. **Skull GUI ImageId** — placeholder acceptable; finalize with MCP tools
4. **startCombatRetreat() exact implementation** — signature is clear, but internal details (waypoint handling, arrival detection) depend on reviewing startMovement() internals
5. **Coordination with existing movement reservations** — may need review if retreat and normal movement can conflict

---

## 8. Clean Draft-Ready Summary

### System: NPC Combat Retreat System

**Trigger:** In `fireMultiLaser()` (NPCCombatSystem line 238), before calling `TakeDamage`, check if `(health - damage) / maxHealth <= 0.10`. If yes, call `NPCRetreatSystem.attemptRetreat(npcModel)`. If true, skip damage. If false, apply damage.

**attemptRetreat(npcModel) → boolean:**
1. If `hasSkull[npcModel]`, return false
2. Get current tile via `npcModel:GetAttribute("CurrentTileId")`
3. Get adjacent tiles via `TileAdjacencyManager.getAdjacentTiles(currentTilePart)`
4. Filter: not occupied (`TileManager.getTileOccupantById`), not reserved (`retreatReservations`), valid territory (same-country OR allied OR conquered)
5. Score each by max distance to nearest enemy within 100 studs
6. Try tiles in score order: reserve in `retreatReservations`, call `startCombatRetreat()`
7. On success: set `hasSkull[npcModel] = true`, show skull GUI, connect HealthChanged, return true
8. If all fail: return false

**startCombatRetreat(npcModel, targetTileKey, targetTilePart):** New function in NPCMovementSystem. Moves NPC to target tile with state "Retreating" (invulnerable). On arrival: update occupancy via TileManager, set state Idle. If destination occupied mid-transit: use existing `startRetreat()` to snap to origin.

**Invulnerability:** Add to both inline `getAllTargets` callbacks in Combat.registerNPC():
```lua
if NPCMovementSystem.isRetreating(target) then
    -- skip this target
end
```
Add at Attacker callback (line ~614) and Defender callback (line ~685).

**Skull Removal:** On HealthChanged, if `health/maxHealth >= 0.30`: `hasSkull[npcModel] = nil`, hide GUI, disconnect connection.

**Cleanup:** On Humanoid.Died/Destroying: clear hasSkull, release retreatReservations, disconnect HealthChanged.

**State Tables (NPCRetreatSystem):**
- `hasSkull: {[Model]: boolean}`
- `retreatReservations: {[TileId]: Model}`
- `healthChangedConnections: {[Model]: RBXScriptConnection}`

**Constants:**
- `RETREAT_HEALTH_THRESHOLD = 0.10`
- `SKULL_REMOVAL_THRESHOLD = 0.30`
- `ENEMY_SCAN_RADIUS = 100`

**Files to Modify:**
- `src/shared/NPCCombatSystem.luau` — damage interception in fireMultiLaser(), target filtering in inline callbacks
- `src/shared/NPCMovementSystem.luau` — add startCombatRetreat()
- **NEW:** `src/shared/NPCRetreatSystem.luau` — attemptRetreat(), skull management, state tables

**Explicit Non-Goals for v1:**
- Exhaustion counter
- Player-controlled retreat
- Chain-retreat during transit
- Health restoration after retreat

---

# Original Consolidation (Preserved Below for Reference)

---

Brainstorm Findings Consolidation
NPC Combat Retreat System — Draft Preparation Document
1. Executive Summary
The NPC Combat Retreat System enables NPCs to flee to an adjacent tile instead of dying when health drops to a critical threshold. The system uses a skull-based recovery gate: after retreating, a skull GUI appears over the NPC, blocking further retreats until health regenerates above a recovery threshold. If an NPC reaches the retreat threshold while the skull is active, it dies.

Core behavior flow:

NPC health drops to ≤10% during combat
If no skull → attempt retreat to safest adjacent tile
If retreat succeeds → skull appears, NPC is invulnerable during movement
If no valid tile exists → NPC dies
If skull is present → NPC dies (cannot retreat again yet)
When health regenerates to ≥30% → skull disappears, retreat available again
The system is automatic-only (no player control), uses world-space Euclidean distance for tile scoring, does not trigger capture mechanics, and treats the exhaustion counter as a future enhancement.

2. Confirmed Decisions
Decision	Reasoning	Implementation Implication
Retreat threshold: 10% health	Low enough to feel dramatic, high enough to allow escape before death	Configurable constant RETREAT_HEALTH_THRESHOLD = 0.10
Skull removal threshold: 30% health	Requires meaningful recovery before re-retreat; not too punishing	Configurable constant SKULL_REMOVAL_THRESHOLD = 0.30
Automatic retreat only	Consistent behavior across all NPCs; no UI complexity	No player input handling required; pure server logic
World-space Vector3 distance scoring	Fast, deterministic, sufficient for 1-hop adjacent tile decisions	(tilePos - enemyPos).Magnitude per enemy, take minimum
No capture during retreat	Retreat is defensive escape, not offensive occupation; prevents exploits	Retreat movement must skip TileOwnershipManager capture logic
No enemy-controlled tiles as destinations	NPCs cannot flee into hostile territory they don't control	Filter out tiles where getEffectiveOwner(tile) ~= npcCountry AND tile is not conquered by NPC's country
Conquered territory IS allowed	Already-occupied enemy territory is under NPC's country control	Check OwnerCountry attribute matches NPC's country
Die if no valid tile exists	Clean fallback; no invulnerability exploits	Return false from attemptRetreat(), let death proceed
Keep current health after retreat	NPC survives at threshold health; must regenerate to remove skull	No health manipulation on retreat success
Skull visible to all players	Strategic information is public; enemies know who is vulnerable	BillboardGui replicated to all clients
Skull GUI: new simple design	No existing pattern to follow	Create BillboardGui with skull ImageLabel; use MCP tools
Humanoid.HealthChanged for skull removal	Event-driven; catches regen outside combat; cheaper than polling	Connect signal, check health/maxHealth >= 0.30, remove skull
Exhaustion is future enhancement	Keep v1 simple; skull mechanic sufficient for initial balance	Design state model to support exhaustion later; add TODO
Invulnerability during retreat movement	Retreating NPC must survive transit	Filter retreating NPCs from combat target lists
3. Provisional Decisions
Provisional Decision	Why Chosen For Now	What Could Change It
Intercept damage in fireMultiLaser() before TakeDamage()	Proactive; avoids health restoration; clean integration point	If other damage sources exist (e.g., environmental), may need HealthChanged fallback
New NPCRetreatSystem module	Isolates retreat logic; lazy-loaded by NPCCombatSystem	Could merge into NPCCombatSystem if scope is small enough
Separate retreatReservations table	reservedTiles in NPCMovementSystem is private	Could expose reservation API from NPCMovementSystem instead
Use modified startRetreat() or new startCombatRetreat()	Existing startRetreat() sets state to "Retreating" and handles invulnerability	May need wrapper if existing function is too coupled to snap-back behavior
Enemy scan limited to 100-stud radius	Optimization; distant enemies don't affect relative tile scoring	May need adjustment based on map scale and NPC density
Skull state stored in module table + attribute	Table for fast server lookup; attribute for client GUI	Could use attribute-only if client needs are simple
4. Open Questions Still Not Fully Resolved
Question	Why It Matters	Temporary Assumption for First Draft
Exact startRetreat() modification vs. new function	Existing startRetreat() is designed for snap-back to origin tile, not forward movement to a new tile	Assume new startCombatRetreat() wrapper that sets target to chosen tile and delegates to existing movement machinery
Health regeneration script location/naming	Need to know if it's consistently named "Health" and is a Script	Assume npcModel:FindFirstChild("Health", true) pattern from existing code is reliable
Skull GUI asset (ImageId)	Need actual skull image for BillboardGui	Use placeholder; finalize asset via MCP tools during implementation
Connection cleanup on mid-retreat death	If NPC dies during retreat (edge case: TileOwnershipManager kills NPCs on capture), HealthChanged connection must be cleaned	Assume cleanup in unregisterNPC() path; add explicit handling in NPCRetreatSystem
Should allied territory be preferred over neutral?	Tile scoring tie-breaker priority	Assume: same-country > allied > conquered > neutral; implement as secondary sort
5. Rejected Alternatives
Rejected Option	Why Rejected	Future Enhancement?
Player-ordered retreat	Adds UI complexity; automatic is simpler and consistent	Possibly, if players request more control
Graph-hop distance scoring	Expensive BFS per enemy; overkill for adjacent-only retreat	No — Euclidean is sufficient
Retreat to any enemy tile	Exploitable; illogical (fleeing into hostile territory)	No
Chain-retreat during transit	Overly complex; destination changes mid-movement are bug-prone	No
Temporary invulnerability on no-tile fallback	Creates exploit potential; user chose death-if-trapped	Possibly, as a "last stand" mechanic
Health restore after retreat	User chose keep-current-health with skull recovery gate	Possibly, as a medic/healing feature
Exhaustion counter in v1	Adds balancing complexity; skull mechanic is sufficient	Yes — design API to support it
Poll health in combat loop for skull removal	Wasteful; NPC may regenerate outside combat	No — event-driven is better
Intercept at Humanoid.Died	Health already 0; must restore it; races with Debris timer	No — pre-damage interception is cleaner
6. Rules Matrix
Condition	Expected Behavior
Lethal damage reached (health would drop ≤10%)	Check skull state; if no skull → attempt retreat; if skull present → allow death
Retreat available (no skull, health ≤10%)	Evaluate adjacent tiles, pick safest, reserve it, start retreat movement
No valid retreat tile exists	Retreat fails; NPC dies normally
Tile is enemy-controlled (not conquered by NPC's country)	Invalid retreat destination; skip during tile evaluation
Tile is friendly (same country)	Valid retreat destination; highest priority in tie-breaker
Tile is allied	Valid retreat destination; second priority in tie-breaker
Tile is conquered enemy territory (OwnerCountry == NPC's country)	Valid retreat destination; third priority in tie-breaker
Tile is neutral/unowned	Valid retreat destination; lowest priority in tie-breaker
Tile capture during retreat	Disabled; retreat movement does NOT trigger TileOwnershipManager capture logic
Retreat while skull is active	Retreat blocked; NPC dies
Health regen above 30% threshold	Skull removed; hasSkull[npc] = nil; hide skull GUI; retreat available again
Repeated retreat attempts (after skull removal)	Allowed; no limit in v1 (exhaustion is future enhancement)
Retreat destination conflict (two NPCs pick same tile)	First to reserve wins; second NPC tries next-best tile; if none available, dies
Movement start failure after tile selection	Release reservation, try next-best tile; if all fail, NPC dies
Destination becomes unsafe during transit	Continue to destination; on arrival, if occupied, snap back to origin via existing startRetreat() logic; NPC now at origin with skull; next lethal hit kills
NPC is retreating (state == "Retreating")	NPC is invulnerable; filtered out of all combat target lists
NPC killed by TileOwnershipManager during retreat	Death proceeds; cleanup connections in unregisterNPC() path
7. Data / State Model Implied by the Brainstorm
Name	Scope	Purpose	Cleanup Point	Required for v1
hasSkull: {[Model]: boolean}	NPCRetreatSystem module	Tracks which NPCs have active skull state	Humanoid.Died, Model.Destroying, unregisterNPC()	Yes
retreatReservations: {[TileId]: Model}	NPCRetreatSystem module	Prevents multiple NPCs claiming same retreat tile	Retreat completion, retreat failure, NPC death	Yes
healthChangedConnections: {[Model]: RBXScriptConnection}	NPCRetreatSystem module	Stores HealthChanged connection for skull removal monitoring	Humanoid.Died, Model.Destroying, skull removal	Yes
exhaustionCount: {[Model]: number}	NPCRetreatSystem module	Tracks retreat count for future exhaustion mechanic	N/A	No (future)
RETREAT_HEALTH_THRESHOLD: number	Constant	Configurable retreat trigger (0.10)	N/A	Yes
SKULL_REMOVAL_THRESHOLD: number	Constant	Configurable skull removal trigger (0.30)	N/A	Yes
IsRetreatingCombat: Attribute	NPC Model	Optional attribute for client-side skull GUI visibility	Retreat completion, NPC death	Maybe (if needed for client)
8. Integration Points with Existing Systems
NPCCombatSystem
What Needs to Happen	What Should NOT Change	Risks Identified
Modify fireMultiLaser() to check if damage would trigger retreat before calling TakeDamage()	Core combat loop structure; damage splitting logic	Invasive change to hot path; must preserve existing behavior for non-retreat cases
Add NPCMovementSystem.isRetreating(target) check in getAllTargets() for both Attacker and Defender loops	Target validation logic for adjacency, diplomacy	Must not break existing target filtering
Lazy-load NPCRetreatSystem to avoid circular dependency	Existing lazy-load pattern	None
NPCMovementSystem
What Needs to Happen	What Should NOT Change	Risks Identified
Use or extend startRetreat() for combat retreat movement, OR create startCombatRetreat()	Existing startRetreat() behavior for snap-back	Must ensure state is set to "Retreating" for invulnerability
isRetreating() already returns correct state	N/A	None — already works
canBeAttacked() exists but is not used by combat loop	N/A	Consider deprecating or documenting
TileAdjacencyManager
What Needs to Happen	What Should NOT Change	Risks Identified
Call getAdjacentTiles(tilePart) to get retreat candidates	Adjacency graph; walkability guarantees	None — read-only usage
Call getEffectiveOwner(tilePart) for territory filtering	N/A	None
Call getTileId(tilePart) for reservation keying	N/A	None
TileManager
What Needs to Happen	What Should NOT Change	Risks Identified
Call getTileOccupantById(tileId) to check if tile is occupied	N/A	None
Call occupyTileById() / releaseTileById() on retreat completion	Existing occupancy tracking	Must coordinate with movement system's tile updates
DiplomacyManager
What Needs to Happen	What Should NOT Change	Risks Identified
Call areCountriesAllied(countryA, countryB) for ally territory detection	N/A	None
Possibly call areCountriesAtWar() for enemy detection during scoring	N/A	None
NPCTargetingHandler
What Needs to Happen	What Should NOT Change	Risks Identified
Already blocks targeting of retreating NPCs via canBeAttacked()	N/A	None — no changes needed
Death Pipeline / Humanoid.Died
What Needs to Happen	What Should NOT Change	Risks Identified
NPCRetreatSystem must clean up hasSkull, retreatReservations, healthChangedConnections on death	Existing cleanup order in setupDeathCleanup()	Must hook into maid or register separate cleanup
If retreat intercepts death, Humanoid.Died should NOT fire	Existing pipeline	Must prevent health from reaching 0, not restore it after
Health Regeneration Handling
What Needs to Happen	What Should NOT Change	Risks Identified
Connect Humanoid.HealthChanged after successful retreat	N/A	Connection must be stored and cleaned up
Check health/maxHealth >= SKULL_REMOVAL_THRESHOLD on each change	N/A	Must handle edge case where NPC is damaged again before threshold
Disconnect and remove skull when threshold reached	N/A	None
9. Likely v1 Scope
Must Be in v1
Retreat trigger at configurable health threshold (10%)
Skull state tracking and GUI display
Skull removal at configurable health threshold (30%)
Adjacent tile evaluation with occupancy filtering
World-space distance scoring
Retreat reservation system
Invulnerability during retreat (target list filtering)
Territory filtering (friendly/allied/conquered only)
No-capture rule during retreat
Die-if-trapped fallback
Cleanup on NPC death
Should Probably Be in v1
Tile ownership tie-breaker (friendly > allied > conquered > neutral)
Enemy scan radius optimization (100 studs)
Debug logging for retreat events
Can Wait Until Later
Fine-tuned skull GUI visual design (placeholder acceptable)
Performance profiling of enemy scan
Metrics/analytics for retreat frequency
Explicit Future Enhancements
Exhaustion counter: Track retreat count; after N retreats, NPC cannot retreat
Player-controlled retreat: Manual retreat order for player-owned NPCs
Retreat priority: High-value NPCs retreat first in simultaneous scenarios
Retreat sound/VFX: Audio/visual feedback on retreat trigger
10. Drafting Notes for the First Implementation Plan
Treat as Settled
All items in Section 2 (Confirmed Decisions)
Rules Matrix behaviors
Integration points with existing systems
v1 scope boundaries
Label as Provisional in First Draft
Exact function signature for startCombatRetreat() vs. modified startRetreat()
Enemy scan radius (100 studs — may need tuning)
Skull GUI asset ID (placeholder)
Tie-breaker priority order (reasonable default, may need balancing)
Areas Needing Careful Wording
Damage interception point: Must be crystal clear that retreat check happens BEFORE TakeDamage() is called, not after
Invulnerability mechanism: Clarify this is achieved by filtering, not by health manipulation
Reservation vs. movement failure: Explain the retry-next-tile flow explicitly
Transit edge cases: State clearly that destination changes during transit are ignored
Prioritize Simplicity
Single module (NPCRetreatSystem) for all new logic
Minimal changes to existing systems (filter additions, not restructuring)
No new events/signals unless absolutely necessary
No client-side logic beyond skull GUI visibility
11. Ready-to-Transfer Design Summary
For GPT-5 Implementation Plan Draft:

System: NPC Combat Retreat System

Trigger: When fireMultiLaser() in NPCCombatSystem would deal damage that drops an NPC's health to ≤10%, check skull state. If no skull, call NPCRetreatSystem.attemptRetreat(npcModel) instead of dealing damage.

Retreat Logic (NPCRetreatSystem.attemptRetreat):

Get adjacent tiles via TileAdjacencyManager.getAdjacentTiles(currentTilePart)
Filter: not occupied (TileManager.getTileOccupantById), not reserved (retreatReservations), valid territory (same country OR allied OR conquered)
Score each by minimum Euclidean distance to any enemy NPC within 100 studs
Tie-break: same-country > allied > conquered > neutral
Reserve best tile: retreatReservations[tileId] = npcModel
Call movement: NPCMovementSystem.startCombatRetreat(npcModel, tileKey, tilePart)
Set skull state: hasSkull[npcModel] = true, show skull BillboardGui
Connect Humanoid.HealthChanged to monitor for skull removal at ≥30%
Return true (retreat succeeded, skip damage)
If no valid tile: return false (retreat failed, deal damage, NPC dies)

Invulnerability: Add to getAllTargets() in both Attacker and Defender combat loops: if NPCMovementSystem.isRetreating(target) then skip

Skull Removal: On HealthChanged, if health/maxHealth >= 0.30: hasSkull[npcModel] = nil, hide GUI, disconnect connection

Cleanup: On Humanoid.Died or Model.Destroying: clear hasSkull, release retreatReservations if any, disconnect HealthChanged connection

Territory Rules: No capture during retreat. Only retreat to: own country tiles, allied tiles, conquered enemy tiles (OwnerCountry == NPC's country). No retreat to enemy-controlled tiles.

State Tables:

hasSkull: {[Model]: boolean}
retreatReservations: {[TileId]: Model}
healthChangedConnections: {[Model]: RBXScriptConnection}
Constants:

RETREAT_HEALTH_THRESHOLD = 0.10
SKULL_REMOVAL_THRESHOLD = 0.30
ENEMY_SCAN_RADIUS = 100
Files to Modify:

src/shared/NPCCombatSystem.luau — damage interception, target filtering
src/shared/NPCMovementSystem.luau — add startCombatRetreat() or modify startRetreat()
NEW: src/shared/NPCRetreatSystem.luau — core retreat logic
Exhaustion: Future enhancement. Design state to support exhaustionCount later.