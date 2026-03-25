ZERO-AMBIGUITY IMPLEMENTATION ROADMAP
Objective
Eliminate state inconsistency, complete the TileId migration, harden lifecycle cleanup, and replace broad runtime scans with authoritative registries/tags.

Non-Negotiable Global Rules
Do not do partial fixes.

If a system has two ownership paths, remove one.
If a tile can be updated visually, logically, and via attribute, all three must be updated in the same code path.
No hybrid authority after this refactor.

TileId becomes the only authoritative tile identity for occupancy.
Positional keys may remain as compatibility metadata, but never as the source of truth.
Every per-NPC signal must have explicit cleanup.

No implicit “Destroy will probably handle it.”
Every connection created by NPCCombatSystem must be owned by a cleanup container.
No broad Workspace NPC scans for runtime logic.

Use CollectionService tags for dynamic NPC iteration.
Use CountryNPCRegistry for country membership queries.
Maintain behavior unless explicitly changing a bug.

Preserve diplomacy, movement, and capture semantics except where the audit identified inconsistency.
PHASE 1 — STATE CRITICALITY
Goal
Fix the stale OwnerCountry attribute bug and make tile ownership updates atomic.

File Path
src/shared/TileOwnershipManager.luau

Current Logic
Ownership state is split across:
OccupiedTerritories[tilePart]
tilePart.Color
tilePart:GetAttribute("OwnerCountry")
In some code paths, color and table state are updated, but OwnerCountry is not.
Specifically dangerous paths:
releaseCountryOccupiedTiles
reclaimTile
Other functions already partially rely on OwnerCountry as authoritative override:
tileEffectivelyBelongsTo
TileAdjacencyManager.getEffectiveOwner
Target Logic
Create a single no-yield ownership mutation path inside TileOwnershipManager.

No-yield rule (mandatory, no exceptions)
No task.wait, task.defer, remote fire, or any yielded call may occur between the visual update (tilePart.Color), the OwnerCountry update (SetAttribute), and the occupied-record update (OccupiedTerritories write).
All three writes must happen together, in the same synchronous code path, before any event is fired.
This is what "atomic" means in Luau — there are no real transactions, so the only guarantee is a single code path with no yields between writes.

Add low-level internal helpers
These helpers isolate individual state dimensions. They are NOT the entry points for public mutations — they are building blocks only:

applyTileVisualOwner(tilePart, ownerCountryName)

Purpose: set tile color to the controlling country's color.
Must:
resolve the correct color from CountryColors
fail loudly with warn if missing color
set tilePart.Color
applyTileOriginalVisual(tilePart, originalColor)

Purpose: restore original visual state.
Must:
set tilePart.Color = originalColor
setTileLogicalOwner(tilePart, ownerCountryNameOrNil)

Purpose: set or clear OwnerCountry
Must:
if ownerCountryNameOrNil is a non-empty string, call tilePart:SetAttribute("OwnerCountry", ownerCountryNameOrNil)
otherwise call tilePart:SetAttribute("OwnerCountry", nil)
setOccupiedRecord(tilePart, occupyingCountry, originalCountry, originalColor)

Purpose: write OccupiedTerritories[tilePart]
clearOccupiedRecord(tilePart)

Purpose: delete OccupiedTerritories[tilePart]
Add high-level state applicators (the only valid public mutation entry points)
Every public function in TileOwnershipManager that changes tile state MUST end by calling exactly one of these three state applicators. No public function may write visual, logical, or occupied state directly — all writes must go through one of these:

applyOccupiedState(tilePart, occupyingCountry, originalCountry, originalColor)

Applies all three writes together:
applyTileVisualOwner(tilePart, occupyingCountry)
setTileLogicalOwner(tilePart, occupyingCountry)
setOccupiedRecord(tilePart, occupyingCountry, originalCountry, originalColor)
No yield between any of these calls.
applyAnnexedState(tilePart, annexingCountry)

Applies annexed state:
applyTileVisualOwner(tilePart, annexingCountry) — color stays as occupying country color (already set)
setTileLogicalOwner(tilePart, annexingCountry)
clearOccupiedRecord(tilePart)
No yield between any of these calls.
applyOriginalState(tilePart, originalColor)

Reverts to geographic/original ownership:
applyTileOriginalVisual(tilePart, originalColor)
setTileLogicalOwner(tilePart, nil)
clearOccupiedRecord(tilePart)
No yield between any of these calls.
Rule: all public mutation paths in TileOwnershipManager must end by calling one of the three applicators above. No exceptions. No mixed direct writes alongside applicator calls.
Define ownership state invariants
After the refactor, the following must always be true:

A. Occupied but not annexed
If a tile is actively occupied:

OccupiedTerritories[tilePart] ~= nil
OwnerCountry == occupyingCountry
tilePart.Color == CountryColors[occupyingCountry]
B. Annexed
If a tile has been annexed:

OccupiedTerritories[tilePart] == nil
OwnerCountry == annexingCountry
tilePart.Color == CountryColors[annexingCountry]
C. Reverted to geographic/original owner
If a tile is no longer occupied and no longer annexed:

OccupiedTerritories[tilePart] == nil
OwnerCountry == nil
tilePart.Color == originalColor
D. Reclaimed by original/geographic owner
If a country reclaims its own original tile:

OccupiedTerritories[tilePart] == nil
OwnerCountry == nil
tilePart.Color == originalColor
Do not leave OwnerCountry set during reclaim-to-original-owner state.

Required Function-by-Function Changes
1. captureTile(tilePart, player)
Current Logic
Sets OwnerCountry
Sets color
Writes occupation record
Has reclaim handling for geographicCountry == playerCountry
Target Logic
Preserve current overall behavior.
Ensure both normal capture and reclaim branch use the atomic helpers.
In reclaim branch:
clear occupied record
clear OwnerCountry if the tile is returning to its geographic owner
restore original color
Do not mix direct writes with helper-driven writes.
Acceptance Criteria
After capture of enemy tile:
OccupiedTerritories[tile] exists
OwnerCountry == attackerCountry
tile color matches attacker country
After reclaiming original homeland tile:
OccupiedTerritories[tile] == nil
OwnerCountry == nil
tile color restored to original
2. releaseTile(tilePart)
Current Logic
Restores color
clears OwnerCountry
removes occupied tracking
Target Logic
Route through atomic helpers only.
Preserve current semantics.
Acceptance Criteria
Releasing an occupied tile returns it to:
original color
no occupied record
no OwnerCountry
3. reclaimTile(tilePart, player)
Current Logic
Restores color
removes occupied tracking
does not clear or reset OwnerCountry
Target Logic
Explicitly return the tile to original-geographic ownership state:
restore original color
clear occupied record
clear OwnerCountry
Do not set OwnerCountry = playerCountry here; reclaimed original land should rely on geography again.
Acceptance Criteria
Reclaiming a tile always ends with:
OccupiedTerritories[tile] == nil
OwnerCountry == nil
original color restored
4. releaseCountryOccupiedTiles(countryName)
Current Logic
Collects occupied tiles
restores color
removes occupied record
does not clear OwnerCountry
Target Logic
For every released tile:

restore original color
clear OwnerCountry
clear occupied record
fire TileCapturedEvent after state is fully applied
Do not mutate visual state and logical state in separate phases.

Acceptance Criteria
Peace treaty release leaves no tile with:
OccupiedTerritories[tile] == nil and OwnerCountry still set
Spot-check released tiles from multiple countries:
visuals and ownership queries agree
5. annexOccupiedTiles(countryName)
Current Logic
sets OwnerCountry
keeps current color
removes occupied record
Target Logic
Preserve annex semantics.
Route through helper functions.
Annexed tile must become:
no occupied record
OwnerCountry == countryName
color remains occupying country's color
Acceptance Criteria
Annexed tiles are logically controlled by annexer even though they remain in original map model hierarchy.
TileAdjacencyManager.getEffectiveOwner(tile) returns annexer.
6. performCountryTakeover(losingCountryName, winningPlayer, losingPlayer)
Current Logic
mixes direct color writes, attribute writes, occupied record updates
Target Logic
Refactor all tile state changes in this function to use the same atomic helper pattern.
For each tile transfer case:
decide final ownership state first
then apply visual + attribute + occupied record together
Acceptance Criteria
After conquest:
no transferred tile has mismatched visual owner vs OwnerCountry
no tile is left with winner color and stale loser OwnerCountry
no released/third-party tile is silently overwritten
File Path
src/shared/TileAdjacencyManager.luau

Current Logic
getEffectiveOwner(tilePart) checks OwnerCountry first, then geographic owner.
This is correct only if OwnerCountry is always clean.
Target Logic
No structural change required.
Keep logic as-is.
Rely on Phase 1 fixes to guarantee correctness.
Acceptance Criteria
After all Phase 1 changes, getEffectiveOwner(tile) must always match the actual controlling country in all tested states:
untouched
occupied
reclaimed
annexed
conquered-transfer
Phase 1 Validation Suite
Run these manual or scripted scenarios:

Capture enemy tile

confirm color, OwnerCountry, occupied record all match attacker
Peace release

confirm color reverted
OwnerCountry == nil
occupied record removed
Reclaim homeland

confirm color reverted
OwnerCountry == nil
occupied record removed
Annex occupied tile

confirm color stays annexer color
OwnerCountry == annexer
occupied record removed
Country takeover

sample capital tile, regular core tile, previously occupied tile, third-party occupied tile
PHASE 2 — TOTAL MIGRATION
Goal
Make TileId the 100% source of truth for occupancy. Remove threshold-based hybrid behavior.

File Path
src/shared/TileManager.luau

Current Logic
Occupancy uses:
GlobalOccupiedTiles[tileKey]
GlobalOccupiedTilesById[tileId]
shouldUseTileIdOccupancy() conditionally enables TileId authority only if ambiguous positional buckets > 10.
This preserves positional-key authority in low-ambiguity maps.
Target Logic
Remove hybrid authority entirely.

Delete or neutralize this behavior
Remove the UseTileIdOccupancy threshold logic as a decision mechanism.
shouldUseTileIdOccupancy() should either:
be deleted entirely, or
always return true
Preferred: delete the function and simplify all callers.

New authoritative occupancy model
Use:

GlobalOccupiedTilesById[tileId] as the sole global occupancy authority
country-local occupancy should also be keyed by TileId, not positional key
Required structural migration
Change these tables:

OccupiedTiles

from: { [countryName] = { [tileKey] = npcModel } }
to: { [countryName] = { [tileId] = npcModel } }
GlobalOccupiedTiles

positional-key global table should be removed from authority
either:
delete it completely, or
keep only as optional debug mirror, never read by logic
Preferred: remove logical reads from it everywhere.

Global authority:
only GlobalOccupiedTilesById[tileId]
Required Function-by-Function Changes
1. getTileIdFromKey(tileKey)
Current Logic
tries to resolve TileId from legacy key
Target Logic
Keep only for compatibility adapters if needed.
Do not use this as the normal occupancy path.
New code should already have TileId before calling occupancy functions.
Acceptance Criteria
No core occupancy function depends on converting a positional key at runtime unless explicitly in a compatibility shim.
No-re-resolution rule (mandatory for all functions in this section)
If a function already has a validated tilePart, it MUST:
use that tilePart directly
get tileId from TileAdjacencyManager.getTileId(tilePart)
never call getTileFromKey(...) or any positional-key lookup on a tilePart it already has
Only fall back to key-based resolution when the function genuinely receives only a legacy tileKey and has no tilePart.
This applies to: occupyTile, releaseTile, occupyTileGlobal, releaseTileGlobal, getSpawnPosition, getAvailableTileCount, and all callers in NPCMovementSystem, NPCTargetingHandler, and NPCSpawner.

2. occupyTile(countryName, tileKey, npcModel)
Current Logic
writes country occupancy by tileKey
writes global occupancy by tileKey
optionally mirrors to TileId table
Target Logic
Change signature behavior internally:

resolve tileId once from the destination tilePart, not from the NPC's CurrentTileId attribute
store only by tileId
if keeping positional keys at all, treat them as legacy convenience only
Implementation requirement:

NEVER derive tileId from npcModel:GetAttribute("CurrentTileId") — that attribute tracks the NPC's current/origin tile and may be stale, nil, or still pointing at the previous tile during spawn, movement, or arrival.
Always resolve the destination tileId from the destination tilePart:
resolve tilePart from tileKey via TileAdjacencyManager.getTileFromKey(tileKey) (or equivalent)
then call TileAdjacencyManager.getTileId(tilePart) to get the authoritative id
Where practical, prefer callers to pass tilePart directly so no key-to-part roundtrip is needed at all.
Then:

OccupiedTiles[countryName][tileId] = npcModel
GlobalOccupiedTilesById[tileId] = npcModel
Do not make global logic depend on tileKey.

Preferred API direction
Where callers already have a tilePart, prefer new overloads:
occupyResolvedTile(countryName, tilePart, npcModel) — accepts tilePart, derives tileId internally
releaseResolvedTile(countryName, tilePart) — same
occupyTileById / releaseTileById — for lowest-level calls that already have a tileId
Legacy tileKey signatures may remain as compatibility shims that delegate to the above.

Acceptance Criteria
Occupying a tile always registers exactly one authoritative TileId entry.
TileId is always resolved from the destination tilePart, never from npcModel attributes.
3. releaseTile(countryName, tileKey)
Current Logic
clears by tileKey
optionally clears TileId entry
Target Logic
resolve tilePart from tileKey, then TileId from tilePart
clear by TileId only for logic
country-local occupancy must also clear by TileId
If tilePart is already available at the call site, pass it directly instead of re-resolving from key.
Acceptance Criteria
Releasing a tile removes only the authoritative TileId entry.
No stale occupancy remains if positional key differs or is ambiguous.
4. occupyTileGlobal(tileKey, npcModel)
Current Logic
writes to positional-key map
optionally mirrors TileId
Target Logic
Refactor to:

resolve tilePart from tileKey, then tileId from tilePart
write only to GlobalOccupiedTilesById
update country-local OccupiedTiles[country][tileId]
If needed, rename to occupyTileGlobalByResolvedTile(tileId, npcModel) or equivalent internal form that accepts a pre-resolved tileId.

Acceptance Criteria
Global occupancy writes are TileId-based only.
5. releaseTileGlobal(tileKey)
Current Logic
clears positional-key map
optionally clears TileId
Target Logic
resolve tilePart from tileKey, then tileId from tilePart (or accept tileId directly if callers already have it)
clear by TileId only
country-local table also cleared by TileId
Acceptance Criteria
No logical occupancy read path depends on positional key.
6. isTileOccupied(tileKey)
7. getTileOccupant(tileKey)
8. isTileOccupiedByPlayer(tileKey, player)
Current Logic
hybrid lookup, may read positional key table
Target Logic
resolve TileId first
query only GlobalOccupiedTilesById[tileId]
If input is still a legacy positional key:

resolve tile part via TileAdjacencyManager.getTileFromKey / fallback
get TileId
then query by TileId
Acceptance Criteria
Reads are TileId-authoritative regardless of input format.
9. occupyTileById, releaseTileById, getTileOccupantById, isTileOccupiedById
Current Logic
already aligned with target direction
Target Logic
These become the preferred low-level APIs.
Make higher-level functions delegate to them.
Acceptance Criteria
All other occupancy logic routes through these or equivalent TileId-based functions.
10. getSpawnPosition(player)
Current Logic
reads OccupiedTiles[countryName][key] by tileKey (line 247) to skip home tiles with standing NPCs
reads GlobalOccupiedTiles[key] by tileKey (line 258) to skip conquered tiles with standing NPCs
Target Logic
After GlobalOccupiedTiles is no longer authoritative:

resolve TileId for each candidate tile (home and conquered)
check isTileOccupiedById(tileId) instead of reading GlobalOccupiedTiles[key]
for home tiles: replace occupied[key] check with TileManager.isTileOccupiedById(tileId)
for conquered tiles: replace GlobalOccupiedTiles[key] check with TileManager.isTileOccupiedById(tileId)
All TileId resolution must occur via TileAdjacencyManager.getTileId(tilePart).

Acceptance Criteria
spawn selection never returns a tile that is already occupied under the TileId authority model
no read of GlobalOccupiedTiles or OccupiedTiles[country][tileKey] remains in this function
11. getAvailableTileCount(countryName)
Current Logic
reads OccupiedTiles[countryName][key] by tileKey to count unoccupied home tiles
After OccupiedTiles[countryName] is migrated to { [tileId] = npcModel }, this lookup always misses every entry and returns an inflated available count.
Target Logic
For each tile position in ValidTiles[countryName]:

resolve the tile part via TileAdjacencyManager.getTileFromKey or equivalent
get its TileId via TileAdjacencyManager.getTileId(tilePart)
check isTileOccupiedById(tileId) for the occupied test
Acceptance Criteria
getAvailableTileCount returns zero for a fully-occupied country under the TileId model
no OccupiedTiles[country][tileKey] read remains in this function
File Path
src/shared/TileKeyUtils.luau

Current Logic
positional rounded keys still widely used
Target Logic
Do not remove this module entirely yet.
Reclassify it as:
compatibility utility
spawn-selection helper
legacy fallback parser
It must not remain the primary identity system.

Acceptance Criteria
no global occupancy authority uses rounded positional keys as the primary index
File Path
src/shared/NPCMovementSystem.luau

Current Logic
still passes/reads targetTileKey
occupancy checks often call TileManager.getTileOccupant(targetTileKey)
Target Logic
Do not remove tileKey from movement routing yet, but normalize all occupancy checks through TileId.

Required updates
Where movement checks occupancy:

resolve targetTilePart
resolve targetTileId
use TileId-backed occupancy calls
Where movement arrives:

when setting occupancy and state, ensure:
CurrentTileId is updated first or in same block
occupancy registration uses TileId authority
Acceptance Criteria
ambiguous positional hashes cannot cause wrong occupant lookup during movement or arrival
File Path
src/server/NPCTargetingHandler.server.luau

Current Logic
tile click flow gets tile key from part and asks TileManager for occupant
Target Logic
preserve interaction flow
ensure tile occupant checks route through TileId-backed resolution
when tilePart is already available (it is — the click handler receives a tilePart), resolve tileId directly from it; do not go through tileKey first
Acceptance Criteria
clicking a tile with an NPC on it always resolves the correct occupant even in ambiguous positional buckets
File Path
src/server/NPCSpawner.luau

Current Logic
calls TileManager.occupyTile(countryName, tileKey, npcClone) on spawn
Target Logic
After TileManager's occupancy APIs are migrated, this caller must be verified and updated.
If occupyResolvedTile(countryName, tilePart, npcModel) exists at this point: prefer it.
If only the tileKey overload remains: ensure it still derives the correct destination TileId internally.
Do not let this caller create legacy-only occupancy entries (i.e., entries only in GlobalOccupiedTiles with no GlobalOccupiedTilesById entry).
Acceptance Criteria
Spawning an NPC writes occupancy under the correct destination TileId.
Spawned NPCs never create only legacy key occupancy entries — the TileId entry must always be present.
GlobalOccupiedTiles prohibition (mandatory, testable)
After Phase 2 migration, GlobalOccupiedTiles MUST NOT be read by any gameplay logic anywhere in the codebase.
If it is kept temporarily (e.g. as a debug mirror), it must not influence:
movement decisions
tile selection or occupant lookup
spawn placement
attack or diplomacy validation
occupancy release or reclaim
Add a prominent comment above the table declaration marking it as "DEBUG ONLY — not read by gameplay logic."
If any function still reads GlobalOccupiedTiles after migration, that is a regression, not a "safety fallback."

Phase 2 Validation Suite
Identify a known ambiguous or potentially ambiguous tile region

Spawn/move NPCs across it

Confirm:

selection works
movement blocking works
occupancy release/reclaim works
no wrong NPC is reported as tile occupant
Log or inspect:

GlobalOccupiedTilesById contains authoritative entries
grep/search confirms zero gameplay reads of GlobalOccupiedTiles remain
PHASE 3 — LIFECYCLE & SIGNAL HYGIENE
Goal
Introduce explicit cleanup ownership for NPCCombatSystem using a Maid/Janitor pattern.

File Path
src/shared/NPCCombatSystem.luau

Current Logic
Per-NPC lifecycle connections are created in:
registerNPC
setupDeathCleanup
Connections are not centrally owned.
unregisterNPC clears tables but does not explicitly disconnect per-NPC lifecycle signals.
Target Logic
Add a lightweight internal Maid/Janitor implementation inside this module.

Required Internal Structure
Add internal Maid implementation
Implement a local utility:

newMaid()
returns a table with:
tasks = {}
Give(task)
DoCleaning()
Give(task) must accept:

RBXScriptConnection
function cleanup callbacks
Instance cleanup if needed
DoCleaning() must:

disconnect all connections
call all cleanup functions
destroy cleanup-owned temporary instances if any
clear table references
Add authoritative per-NPC state bag
Create:

npcRuntime[npcModel] = { maid = ..., ... }
This state bag should own all per-NPC signals created by combat registration.

At minimum store:

maid
any future loop-specific cleanup references if applicable
Required Function-by-Function Changes
1. setupDeathCleanup(npcModel)
Current Logic
attaches humanoid.Died:Once(...)
no owned cleanup handle
Target Logic
remove hidden ownership
either:
inline this into registerNPC, or
pass in the NPC’s maid and register the Died connection through it
If using :Once(), still store the returned connection in the maid.

Acceptance Criteria
death cleanup connection is explicitly owned by the NPC maid
2. registerNPC(npcModel, ownerPlayer, role)
Current Logic
writes owner/role tables
attaches Destroying
calls setupDeathCleanup
starts combat loop
Target Logic
registerNPC must be idempotent. If called on an already-registered NPC:
the old maid must be fully cleaned (DoCleaning called) before the new maid is created
the old npcRuntime entry must be replaced, not accumulated
no duplicate Destroying or Died callbacks may survive after re-registration
behavior must be deterministic regardless of how many times registerNPC is called
This matters because the codebase has: ownership transfers (transferOwnership), Auto-Fix re-registration (periodic re-sync), and possible repeated registration flows.

Order of operations must be:

If existing runtime state exists for npcModel: call existing maid:DoCleaning(), nil the entry.
Create fresh maid.
Create fresh runtime bag: npcRuntime[npcModel] = { maid = maid }.
Register Destroying connection through maid.
Register Humanoid.Died connection through maid (replaces setupDeathCleanup's hidden ownership).
Update owner/role tables.
Start combat loop as before.
Acceptance Criteria
Re-registering the same NPC does not accumulate duplicate Destroying or Died callbacks.
Calling registerNPC three times in a row on the same NPC leaves exactly one live set of lifecycle signals.
3. unregisterNPC(npcModel)
Current Logic
clears combat tables
does not explicitly disconnect per-NPC signals
Target Logic
The cleanup order is mandatory. Deviating from this order is a bug:

Step 1: fetch npcRuntime[npcModel]
Step 2: if present, call runtime.maid:DoCleaning() — this disconnects all signals while combat tables still have context
Step 3: set npcRuntime[npcModel] = nil
Step 4: clear all combat state tables (manualTargets, npcOwners, npcRoles, npcCooldown, defenderAttackers, attackerThreats, pathTimestamps, combatLoops, npcInCombat)
Why order matters: if step 4 runs before step 2, any cleanup callbacks inside the maid run with already-nilled combat tables and may silently fail or produce partial behavior.

Acceptance Criteria
After unregister:
no owned connections remain alive for that NPC
all combat metadata tables are nilled
repeated unregister calls are safe (idempotent — second call finds nil runtime and skips DoCleaning without error)
4. transferOwnership(npcModel, newOwner)
Current Logic
clears manual targets/threat links
updates owner
does not reset movement system
does not coordinate lifecycle with movement
Target Logic
Add explicit integration with NPCMovementSystem.

Required behavior:

after ownership change:
clear combat intent as today
call NPCMovementSystem.OnOwnerChanged(npcModel)
This requires lazy-loading NPCMovementSystem exactly like other circular-sensitive modules.

Acceptance Criteria
an NPC that changes owner cannot retain:
active movement monitor
stale reservation
retreat state
stale IsMoving
File Path
src/shared/NPCMovementSystem.luau

Current Logic
exposes OnOwnerChanged
not clearly invoked by ownership transfer paths
Target Logic
No major internal redesign needed in this phase. Ensure this function becomes part of the ownership-transfer contract.

Also fix one correctness issue found in audit:

Fix dead branch in monitorMovement
corridorOrigin is referenced at the "Apply path correction" block but is never declared as a local variable or parameter anywhere in monitorMovement's scope.
In Luau, referencing an undefined upvalue resolves to nil, so the if corridorOrigin then block is permanently dead code and getPathCorrectedPosition is never called.
Required fix: remove the dead branch entirely (the two lines: if corridorOrigin then / effectiveTarget = getPathCorrectedPosition... / end).
Do NOT attempt to "correctly define corridorOrigin from movement state" — the movement state has no such concept; the branch was never wired up and has no known caller context. Silently deleting it is the correct, safe fix.
Do not leave unreachable correction logic.

Acceptance Criteria
ownership transfer always resets movement state
no undefined local references remain in path correction logic
File Path
src/server/Auto-Fix.server.luau

Current Logic
may call Combat.transferOwnership
Target Logic
No direct structural change required if Combat.transferOwnership is fixed. But verify all reassignment paths use that function rather than bypassing it.

Acceptance Criteria
Auto-fix ownership correction also resets movement state indirectly via combat transfer
File Path
src/server/CountryManager.server.luau

Current Logic
transfers NPCs when country is released/claimed
uses combat ownership transfer
Target Logic
Same as above:

ensure all ownership changes flow through the corrected Combat.transferOwnership
Acceptance Criteria
country release / reclaim / inheritance cannot leave NPCs moving under old owner state
Phase 3 Validation Suite
Spawn NPC

Register -> unregister -> register again

confirm no duplicate Died/Destroying behavior
Move NPC, then transfer ownership mid-move

confirm:
movement stops/reset
reservation released
IsMoving cleared
NPC can receive fresh orders
Transfer to nil/country-owned

confirm idle state and no residual movement/combat ownership leaks
PHASE 4 — OPTIMIZATION & ITERATION AUTHORITY
Goal
Replace runtime Workspace:GetChildren() NPC scans with tag-based iteration or CountryNPCRegistry.

File Path
src/server/NPCTargetingHandler.server.luau

Current Logic
initializes NPC connections via workspace:GetChildren()
tracks new NPCs via workspace.ChildAdded
cleanup via workspace.ChildRemoved
assumes NPCs are direct children of Workspace
Target Logic
Use CollectionService and the RegisteredNPC tag as the sole runtime NPC discovery path.

Required Changes
Replace initialization
Current:

loop through workspace:GetChildren()
Target:

CollectionService:GetTagged("RegisteredNPC")
call connectNPC for each
Replace dynamic add/remove listeners
Current:

workspace.ChildAdded
workspace.ChildRemoved
Target:

CollectionService:GetInstanceAddedSignal("RegisteredNPC")
CollectionService:GetInstanceRemovedSignal("RegisteredNPC")
Preserve cleanup
disconnectNPC(npcModel) remains valid
selectedNPC cleanup on removal remains necessary
Acceptance Criteria
NPC interaction registration works even if NPCs are moved into folders/models later
no dependency on direct workspace child status remains
File Path
src/server/CountryManager.server.luau

Current Logic
getCountryNPCs(countryName) scans Workspace:GetChildren()
Target Logic
Delete getCountryNPCs(countryName) entirely. Do not:
refactor it to use the registry but leave the function around
comment it out
leave it as a "fallback" or "backup" path
The function must not exist in the file after this change. Having it present at all — even dead — creates a second authority path that future code may accidentally invoke.

Inline its single use: refactor transferCountryNPCs(countryName, newOwner) to call CountryNPCRegistry.getNPCs(countryName) directly, without going through getCountryNPCs.

Acceptance Criteria
getCountryNPCs does not exist anywhere in CountryManager after this change
country NPC transfer count matches registry count
no workspace child scan remains for country army lookup
File Path
src/server/Diagnostics.server.luau

Current Logic
uses tags first
falls back to workspace:GetChildren() if no tagged NPCs
Target Logic
Remove fallback workspace scan. This fallback masks tagging failures and creates dual authority.

Replace with:

if no tagged NPCs, log that zero tagged NPCs exist
do not scan workspace as a backup
Acceptance Criteria
diagnostics only trusts tagged NPCs
missing tags surface as a real issue instead of being silently bypassed
File Path
src/server/Auto-Fix.server.luau

Current Logic
already uses CollectionService:GetTagged("RegisteredNPC")
Target Logic
No structural change needed. Keep as tag-driven.

Acceptance Criteria
remains tag-authoritative
File Path
src/server/NPCSpawner.luau

Current Logic
adds RegisteredNPC tag
registers into CountryNPCRegistry
Target Logic
No major structural change needed. This becomes the canonical source for:

tag presence
country registry membership
Verify cleanup path symmetry:

spawn:
add tag
register country
cleanup:
remove tag
unregister country
Acceptance Criteria
every spawned NPC is tagged and registered exactly once
every cleaned-up NPC is untagged and unregistered exactly once
File Path
src/server/CountryNPCRegistry.luau

Current Logic
register/unregister/getNPCs/hasNPCs
leaves empty country subtables
Target Logic
Tighten unregister:

after removing npcModel, if country table is empty, set it to nil
Optional but recommended:

ensure getNPCs(countryName) only returns live NPCs with Parent ~= nil
Acceptance Criteria
empty country registry buckets do not linger forever
callers get cleaner results
CROSS-PHASE CLEANUP TASKS
File Path
src/server/DiplomacyServer.server.luau

Current Logic
pending requests stored indefinitely
Target Logic
Add request expiry and cleanup. Not core to the 4 mandated phases, but should be done immediately after them.

Required:

timestamp pending requests
cleanup on:
sender leave
receiver leave
timeout expiry
Acceptance Criteria
no indefinite growth of PendingDiplomacyRequests
File Path
src/shared/ServerState.luau

Current Logic
still contains OccupiedTerritories data structure
no longer clearly authoritative relative to TileOwnershipManager
Target Logic
Deprecate or remove ServerState.OccupiedTerritories if unused by authoritative logic. Do not maintain duplicate occupation truth.

Acceptance Criteria
only one authoritative occupied-territory model exists
EXECUTION ORDER FOR SONNET 4.6
Pass 1 — Atomic ownership correctness
Files:

src/shared/TileOwnershipManager.luau
validate against src/shared/TileAdjacencyManager.luau
Pass 2 — TileId authority migration
Files:

src/shared/TileManager.luau
src/shared/NPCMovementSystem.luau
src/server/NPCTargetingHandler.server.luau
src/server/NPCSpawner.luau (verify occupancy caller is updated)
keep src/shared/TileKeyUtils.luau as compatibility-only
Pass 3 — Lifecycle cleanup
Files:

src/shared/NPCCombatSystem.luau
src/shared/NPCMovementSystem.luau
verify integration points in:
src/server/Auto-Fix.server.luau
src/server/CountryManager.server.luau
Pass 4 — Runtime iteration optimization
Files:

src/server/NPCTargetingHandler.server.luau
src/server/CountryManager.server.luau
src/server/Diagnostics.server.luau
src/server/CountryNPCRegistry.luau
FINAL ACCEPTANCE CHECKLIST
Ownership correctness
No tile can exist in a state where:
color says A
OwnerCountry says B
occupied record says nil or C
Tile identity correctness
All occupancy reads and writes are TileId-authoritative
ambiguous positional keys cannot change gameplay outcome
Lifecycle correctness
Per-NPC combat signals are explicitly owned and cleaned
ownership transfer resets movement state every time
Runtime iteration correctness
No gameplay-critical NPC iteration relies on Workspace:GetChildren()
dynamic NPC discovery is tag-driven
country membership queries use CountryNPCRegistry
WHAT SONNET 4.6 SHOULD NOT DO
Do not leave temporary hybrid reads “for safety.”
Do not patch only one release/reclaim function and leave the others mixed.
Do not keep positional-key occupancy as a hidden fallback in gameplay logic.
Do not add Maid infrastructure without actually routing all combat lifecycle signals through it.
Do not keep workspace NPC scan fallback in diagnostics or targeting.
Do not leave getCountryNPCs in CountryManager — delete it entirely, do not just redirect it.
Do not derive destination TileId from npcModel:GetAttribute(“CurrentTileId”) — always resolve from the destination tilePart.
Do not re-resolve tilePart from tileKey when tilePart is already available — use it directly.
Do not read GlobalOccupiedTiles in any gameplay logic path after Phase 2 — not as a “safety net,” not as a “fallback.”
Do not clear combat state tables before calling maid:DoCleaning() in unregisterNPC — DoCleaning must run first.
Do not call registerNPC on an already-registered NPC without cleaning up the old maid first — re-registration must be fully idempotent.
Do not add a task.wait, task.defer, or remote fire between any of the three tile state writes (Color, OwnerCountry attribute, OccupiedTerritories) — all three must be written in the same synchronous block.
