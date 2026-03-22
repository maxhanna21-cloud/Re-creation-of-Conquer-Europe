# NPC Movement & Tile Adjacency Fix Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three NPC movement/adjacency bugs: (1) NPCs falling off cliff faces during tile transitions, (2) adjacency detection failing for narrow-strait tiles like Όρος Άθως, (3) arrival pathfinding routing NPCs through neighboring tiles' territory.

**Architecture:** Three independent surgical changes — no new files, no threshold tuning, no rearchitecting. (1) Y-flatten all `humanoid:MoveTo()` targets so NPCs walk horizontally instead of descending toward cliff faces. (2) Skip the `validateProofEndpoints` function for strait-classified tile pairs since the path between edge points crosses water by definition. (3) Validate that PathfindingService arrival waypoints stay within the destination tile's oriented bounding box; if any waypoint is off-tile, fall back to cell-based BFS which is constrained to the tile's raster footprint.

**Tech Stack:** Luau, Roblox `Humanoid:MoveTo()`, `TileAdjacencyManager` raster/strait pipeline, `PathfindingService`, `isPositionOnTile` OBB check

---

## Root Cause Analysis

### Bug 1 — NPC falls off map (Denmark: Schleswig-Holstein → Lolland Kommune)

**What happens:** The NPC walks from the tile center at Y≈7.6 (surface + humanoid height) toward the departure edge waypoint at Y≈4.6 (tile AABB top surface). The `humanoid:MoveTo(effectiveTarget)` call on every Heartbeat frame uses the raw waypoint Y=4.6, causing the humanoid to seek a lower position. This directs the NPC downward toward the cliff face at the tile boundary, and the NPC walks off the edge into the void. After ~3 seconds of falling, the gap-crossing teleport eventually fires and warps the NPC to the destination tile center.

**Root cause location:** `NPCMovementSystem.luau`, lines ~1496-1503. The "STILL MOVING" section only Y-flattens the MoveTo target for the final tile-center waypoint (`if isFinalTileDest`). For all intermediate waypoints (including edge waypoints at Y=4.6), the raw Y is used.

**Evidence from logs:**
```
[NPCMovement:Waypoints] Edge check: Schleswig-Holstein -> Lolland Kommune, edgeDist=0.179, pointA=(56.5,4.6,246.3), pointB=(56.5,4.6,246.5)
[NPCMovement:GroundCheck] Near waypoint but no ground within 20 studs for AttackerNPC  ← NPC fell off
[NPCMovement:GapCross] Teleporting AttackerNPC past arrival edge to tile waypoint at (55.0, 7.6, 248.5)  ← 3 sec later
```

### Bug 2 — Adjacency fails for narrow-strait tiles (Greece: Κεντρική Μακεδονία → Όρος Άθως)

**What happens:** The tiles are physically adjacent with a narrow water strait (0.71 studs gap). `_classifyCandidatePair()` correctly identifies this as a strait crossing. The `diagnoseAdjacency()` function reports "Phase 2 PASS: narrow strait." But the actual adjacency pipeline (both init-time and runtime repair) calls `validateProofEndpoints()` after classification, and the void-ratio check inside it rejects the pair. The diagnostic function does NOT run `validateProofEndpoints`, which is why it shows PASS while the pipeline rejects.

**Root cause location:** `TileAdjacencyManager.luau`, the `validateProofEndpoints` function (lines 776-795). The void-ratio check samples 5 points along the path between the two edge points. For strait crossings, this path crosses water — so most samples hit void. If >60% hit void, the pair is rejected. This check was designed for land crossings and is counterproductive for water straits.

**Evidence from logs:**
```
Phase 2 PASS: narrow strait (segment=2.47, water gap=0.71)  ← diagnostic says PASS
[Movement] Runtime adjacency repair did not connect: Κεντρική Μακεδονία <-> Όρος Άθως  ← but repair fails
Movement failed: Target tile (Όρος Άθως) is not adjacent  ← movement blocked
```

Additionally, Όρος Άθως has only 2 raster cells (tile size: 5.465 × 4.070 studs). The `ENDPOINT_PROXIMITY_FALLBACK` of 2 studs may not reach the edge point, which could be ~2.7 studs from the tile center.

### Bug 3 — NPC walks through neighboring tiles (Sweden: Södermanlands län → Västmanlands län)

**What happens:** After the gap-crossing teleport, the NPC follows PathfindingService-generated arrival waypoints from the entry edge to the tile center. But PathfindingService uses Roblox's global NavMesh, which spans ALL tiles. The computed path routes south (back toward the origin tile) then west then north — crossing through Södermanlands län and potentially other tiles' territory. The NPC walks over other countries' tiles for ~8 seconds to traverse what should be a simple adjacent move.

**Root cause location:** `NPCMovementSystem.luau`, lines ~930-945. The `computeWalkablePath()` call generates arrival waypoints using PathfindingService without any tile-boundary constraint. The cell-based BFS fallback (Strategy 2) IS tile-constrained but is never tried because PathfindingService succeeds (with an off-tile path).

**Evidence from logs:**
```
[NPCMovement:Waypoints] Built 14 enriched waypoints:
  [3] edge at (12.3, 4.6, 308.3) (Västmanlands län)  ← entry point
  [4] pathfind at (12.9, 7.6, 304.4) (Västmanlands län)  ← goes SOUTH (backward!)
  [5] pathfind at (11.0, 7.6, 302.7)  ← further south, into Södermanlands län territory
  ...8 more waypoints circling around...
  [14] tile at (17.2, 7.6, 312.1) (Västmanlands län)  ← finally arrives
```

Västmanlands län OBB Z-range is [305.6, 319.9]. Waypoint 4 at Z=304.4 and waypoint 5 at Z=302.7 are both OUTSIDE the tile's bounds, confirming the path crosses into neighboring tiles.

---

## File Structure

Two files modified, no new files created:

- **Modify:** `/Users/maximushanna/Documents/Re-creation of Conquer Europe/src/shared/NPCMovementSystem.luau` (~2090 lines)
  - Task 1: Replace Y-conditional MoveTo with always-flattened MoveTo at lines ~1496-1503
  - Task 3: Insert off-tile validation block after the `computeWalkablePath` call at line ~931

- **Modify:** `/Users/maximushanna/Documents/Re-creation of Conquer Europe/src/shared/TileAdjacencyManager.luau` (~2619 lines)
  - Task 2a: Add `and classification ~= "strait"` to Phase 1 init endpoint validation condition at line ~1321
  - Task 2b: Wrap Phase 2 init endpoint validation in `if classification ~= "strait"` at line ~1483
  - Task 2c: Wrap tryRepairAdjacencyPair Phase 2 endpoint validation in `if classification ~= "strait"` at line ~2479

**IMPORTANT:** Edit these files using the Edit tool on the local `.luau` files on disk. Do NOT use the Roblox Studio MCP `multi_edit` tool.

---

### Task 1: Y-flatten ALL MoveTo targets in the movement loop

**Bug fixed:** Denmark — NPC falls off cliff faces when walking toward edge waypoints at Y=4.6.

**Files:**
- Modify: `/Users/maximushanna/Documents/Re-creation of Conquer Europe/src/shared/NPCMovementSystem.luau`

**Why this is safe:** Roblox humanoids follow the ground surface via physics regardless of the `MoveTo` target's Y coordinate. The Y component only affects the *direction* the humanoid tries to move. By flattening Y to `root.Position.Y`, the humanoid walks horizontally while physics handles elevation changes (stepping up curbs, descending gentle slopes). This is already how the final tile-center waypoint works — this change just extends it to ALL waypoints.

- [ ] **Step 1: Read the file and find the exact code to change**

Read `/Users/maximushanna/Documents/Re-creation of Conquer Europe/src/shared/NPCMovementSystem.luau` starting around line 1490. Find this exact 6-line block:

```luau
	-- For the final tile-centre waypoint, flatten the target to the NPC's current
	-- floor Y so the humanoid navigates horizontally rather than toward an elevated
	-- point.  The heartbeat XZ check (FINAL_TILE_ARRIVAL_THRESHOLD) handles arrival.
	if isFinalTileDest then
		humanoid:MoveTo(Vector3.new(effectiveTarget.X, root.Position.Y, effectiveTarget.Z))
	else
		humanoid:MoveTo(effectiveTarget)
	end
```

- [ ] **Step 2: Replace with always-Y-flattened MoveTo**

Using the Edit tool on the file at `/Users/maximushanna/Documents/Re-creation of Conquer Europe/src/shared/NPCMovementSystem.luau`, replace the exact 6-line block from Step 1 with this 4-line replacement:

```luau
	-- Flatten ALL MoveTo targets to the NPC's current floor Y so the humanoid
	-- navigates horizontally. Without this, edge waypoints at tile-surface height
	-- (Y≈4.6) cause the humanoid to walk downward toward cliff faces and fall off.
	-- Roblox physics keeps the humanoid grounded regardless of MoveTo Y.
	humanoid:MoveTo(Vector3.new(effectiveTarget.X, root.Position.Y, effectiveTarget.Z))
```

**What changed:** Removed the `if isFinalTileDest then ... else ... end` conditional. Now ALL waypoints (edge, pathfind, tile) get Y-flattened to the NPC's current standing height. The `else` branch that used `humanoid:MoveTo(effectiveTarget)` with the raw Y is deleted.

- [ ] **Step 3: Verify the edit**

Read back lines ~1490-1510 of the modified file. Confirm:
- The `if isFinalTileDest then` block is GONE
- There is a single `humanoid:MoveTo(Vector3.new(effectiveTarget.X, root.Position.Y, effectiveTarget.Z))` line
- The emergency brake code (`if not hasGroundAhead(...)`) still exists ABOVE the MoveTo line (it should be unchanged)

---

### Task 2: Skip endpoint validation for strait-classified tile pairs

**Bug fixed:** Greece — adjacency detection fails for narrow-strait tiles (Κεντρική Μακεδονία ↔ Όρος Άθως) because `validateProofEndpoints` void-ratio check rejects water crossings.

**Files:**
- Modify: `/Users/maximushanna/Documents/Re-creation of Conquer Europe/src/shared/TileAdjacencyManager.luau`

**Why this is safe:** The `_classifyCandidatePair()` function already validates strait geometry thoroughly: water gap ≤ 5 studs, no cliff failures, consecutive-miss pattern consistent with water, ground ratio checks, no intervening tiles. The `validateProofEndpoints` void-ratio check adds no value for straits (the path IS over water) and its endpoint-hit check fails for tiny tiles. For non-strait (land) classifications, `validateProofEndpoints` continues to run exactly as before — no change to land adjacency behavior.

- [ ] **Step 2a: Fix Phase 1 init — add strait skip to condition**

Read `/Users/maximushanna/Documents/Re-creation of Conquer Europe/src/shared/TileAdjacencyManager.luau` and find this exact code inside the `calculateAdjacenciesFromFootprints` function (around line 1321):

```luau
									if edgeDist > 0 then
										epValid, epReason = validateProofEndpoints(tileA, tileB, crossing.pointA, crossing.pointB)
									end
```

Using the Edit tool, replace those 3 lines with:

```luau
									-- Skip endpoint validation for straits: _classifyCandidatePair
									-- already validated the crossing geometry with multiple raycasts.
									-- validateProofEndpoints void-ratio check rejects straits because
									-- the path between edge points crosses water by definition.
									if edgeDist > 0 and classification ~= "strait" then
										epValid, epReason = validateProofEndpoints(tileA, tileB, crossing.pointA, crossing.pointB)
									end
```

**What changed:** Added `and classification ~= "strait"` to the `if` condition. When `_classifyCandidatePair` returns `"strait"`, `epValid` stays `true` (its initial value from line ~1319) and endpoint validation is skipped.

- [ ] **Step 2b: Fix Phase 2 init — wrap validation in strait check**

In the same file, find this exact code inside the `calculateExtendedAdjacencies` function (around line 1481):

```luau
			if classification and crossing then
				-- Evidence gate: validate proof endpoints hit the correct tiles
				local epValid, epReason = validateProofEndpoints(tileA, tileB, crossing.pointA, crossing.pointB)
				if epValid then
```

Using the Edit tool, replace those 4 lines with:

```luau
			if classification and crossing then
				-- Evidence gate: validate proof endpoints hit the correct tiles.
				-- Skip for strait classifications — path crosses water by definition,
				-- and _classifyCandidatePair already validated the crossing geometry.
				local epValid = true
				local epReason = nil
				if classification ~= "strait" then
					epValid, epReason = validateProofEndpoints(tileA, tileB, crossing.pointA, crossing.pointB)
				end
				if epValid then
```

**What changed:** Instead of always calling `validateProofEndpoints`, it is now wrapped in `if classification ~= "strait"`. For strait pairs, `epValid` defaults to `true` and `epReason` defaults to `nil`, so the pair proceeds to registration. For non-strait (land) pairs, behavior is identical to before.

- [ ] **Step 2c: Fix runtime repair — wrap validation in strait check**

In the same file, find this exact code inside the `tryRepairAdjacencyPair` function (around line 2478):

```luau
			if classification and classifyCrossing then
				local epValid = validateProofEndpoints(tileA, tileB, classifyCrossing.pointA, classifyCrossing.pointB)
				if epValid then
```

Using the Edit tool, replace those 3 lines with:

```luau
			if classification and classifyCrossing then
				-- Skip endpoint validation for straits — water crossing by definition
				local epValid = true
				if classification ~= "strait" then
					epValid = validateProofEndpoints(tileA, tileB, classifyCrossing.pointA, classifyCrossing.pointB)
				end
				if epValid then
```

**What changed:** Same pattern as Step 2b. Strait-classified pairs skip `validateProofEndpoints` in the runtime repair path.

- [ ] **Step 2d: Verify all changes — search for validateProofEndpoints calls**

Read back each of the three modified sections. Then search the entire file for all calls to `validateProofEndpoints` to confirm:

1. **Phase 1 init** (`calculateAdjacenciesFromFootprints`): Condition is now `if edgeDist > 0 and classification ~= "strait" then` ✓
2. **Phase 2 init** (`calculateExtendedAdjacencies`): Wrapped in `if classification ~= "strait" then` ✓
3. **tryRepairAdjacencyPair Phase 2**: Wrapped in `if classification ~= "strait" then` ✓
4. **tryRepairAdjacencyPair Phase 1 parity** (around line 2463): Should be UNCHANGED — this path uses `_getBestWalkableBorderCrossing` (land-only, no classification), so the strait skip does not apply here. Verify it still reads `epValid = validateProofEndpoints(tileA, tileB, bestCrossing.pointA, bestCrossing.pointB)` without any strait condition.

---

### Task 3: Validate arrival pathfinding stays within tile boundaries

**Bug fixed:** Sweden — NPCs walk through neighboring tiles' territory during arrival pathfinding because PathfindingService routes through the global NavMesh.

**Files:**
- Modify: `/Users/maximushanna/Documents/Re-creation of Conquer Europe/src/shared/NPCMovementSystem.luau`

**Why this is safe:** `TileAdjacencyManager.isPositionOnTile()` checks the tile's oriented bounding box (OBB), which is generous — only clearly off-tile waypoints are rejected. The fallback (cell-based BFS via `TileAdjacencyManager.findCellPath`) uses A* through the tile's raster footprint cells, which is guaranteed to stay within the tile. If BFS also fails, the existing fallback inserts no intermediates and the gap-crossing teleport warps the NPC directly to the tile center — the safest outcome.

- [ ] **Step 1: Read the file and find the insertion point**

Read `/Users/maximushanna/Documents/Re-creation of Conquer Europe/src/shared/NPCMovementSystem.luau` starting around line 928. Find the arrival pathfinding section that looks like this:

```luau
				local arrivalSafeCenter = getTileSpawnPosition(currTile)

				-- Strategy 1: PathfindingService
				local arrivalPath = computeWalkablePath(lastWP.position, arrivalSafeCenter)

				if #arrivalPath > 0 then
```

Note the exact position: the `computeWalkablePath` call, then a blank line, then `if #arrivalPath > 0 then`.

- [ ] **Step 2: Insert tile boundary validation between path computation and the existing if-check**

Using the Edit tool, find the exact string:

```luau
				local arrivalPath = computeWalkablePath(lastWP.position, arrivalSafeCenter)

				if #arrivalPath > 0 then
```

Replace it with:

```luau
				local arrivalPath = computeWalkablePath(lastWP.position, arrivalSafeCenter)

				-- Validate arrival path stays within tile boundaries.
				-- PathfindingService uses the global NavMesh and can route through
				-- neighboring tiles. If any waypoint is off-tile, discard the path
				-- and fall back to cell-based BFS (constrained to raster footprint).
				if #arrivalPath > 0 then
					for _, pfPos in ipairs(arrivalPath) do
						if not TileAdjacencyManager.isPositionOnTile(currTile, pfPos) then
							if DEBUG then
								print(string.format(
									"[NPCMovement:Waypoints] Arrival path on %s crosses tile boundary at (%.1f, %.1f, %.1f), falling back to cell-based BFS",
									currTile.Name, pfPos.X, pfPos.Y, pfPos.Z))
							end
							arrivalPath = {}
							break
						end
					end
				end

				if #arrivalPath > 0 then
```

**What changed:** A new validation block is inserted between the `computeWalkablePath` call and the original `if #arrivalPath > 0 then` check. For each PathfindingService waypoint, it checks if the XZ position is inside the destination tile's OBB using `TileAdjacencyManager.isPositionOnTile(currTile, pfPos)`. If ANY waypoint is outside the tile, the entire `arrivalPath` is cleared (`arrivalPath = {}`), which causes the original `if #arrivalPath > 0` to fall through to the `else` branch that tries cell-based BFS.

- [ ] **Step 3: Verify the edit**

Read back lines ~928-960 of the modified file. The code flow should now be:
1. `computeWalkablePath` → `arrivalPath`
2. **NEW:** Validation loop — check each waypoint against `isPositionOnTile`, clear array if any fails
3. **EXISTING:** `if #arrivalPath > 0 then` → insert pathfind waypoints into enriched waypoints
4. **EXISTING:** `else` → try cell-based BFS via `TileAdjacencyManager.findCellPath`

Verify that the EXISTING `if #arrivalPath > 0 then` block and its `else` branch (cell-based BFS) and inner `else` branch ("WARNING: No arrival path found") are ALL still present and unchanged.

---

### Task 4: In-game verification

**Files:** None (gameplay testing only)

- [ ] **Step 1: Start the game in Roblox Studio Play mode**

- [ ] **Step 2: Test Denmark fix (Task 1) — NPC should NOT fall off the map**

1. Select a country that owns Schleswig-Holstein (Germany) or is at war with Denmark
2. Buy an Attacker NPC on Schleswig-Holstein
3. Click on Lolland Kommune (Denmark island south of Schleswig-Holstein) to move the NPC
4. **PASS:** NPC walks horizontally to the tile edge, gets teleported across the gap to Lolland's center in under 2 seconds. Console does NOT show `[NPCMovement:GroundCheck] Near waypoint but no ground within 20 studs`.
5. **FAIL:** NPC visibly falls off the tile edge or console shows ground-check warnings → verify Step 2 of Task 1 was applied correctly (the `if isFinalTileDest` block must be fully removed).

- [ ] **Step 3: Test Greece fix (Task 2) — movement should succeed, not fail with "not adjacent"**

1. Select Greece as your country
2. Buy an Attacker NPC on Κεντρική Μακεδονία (Central Macedonia, the large green/colored tile)
3. Click on Όρος Άθως (Mount Athos — the tiny peninsula south-southeast of Macedonia)
4. **PASS:** Movement succeeds. The NPC moves to Όρος Άθως. Console shows successful movement logs.
5. **FAIL:** Console shows "Movement failed: Target tile (Όρος Άθως) is not adjacent" → check the TileAdjacencyManager init output for `Narrow-strait adjacency: Κεντρική Μακεδονία <-> Όρος Άθως`. If this line is missing, the Phase 2 `classification ~= "strait"` change (Step 2b) was not applied correctly.

- [ ] **Step 4: Test Sweden fix (Task 3) — NPC should stay within destination tile**

1. Select Sweden as your country
2. Buy an Attacker NPC on Södermanlands län
3. Click on Västmanlands län (the tile to the north/northwest) to move the NPC
4. **PASS:** Console shows `[NPCMovement:Waypoints] Arrival path on Västmanlands län crosses tile boundary` followed by cell-based BFS usage. NPC moves within Västmanlands län's territory — does NOT walk south through Södermanlands län or other tiles.
5. **FAIL:** NPC still walks through other tiles' territory → verify the validation block (Step 2 of Task 3) was inserted BEFORE the original `if #arrivalPath > 0 then`, not after it.

- [ ] **Step 5: Regression check — verify normal adjacent tile movement still works**

Move NPCs between 3-4 normal adjacent land tiles that have always worked (e.g., France↔Germany border tiles, or any other well-connected tiles). Verify:
- Movement succeeds without errors
- NPCs walk smoothly between tiles
- No new console errors or warnings
- The TileAdjacencyManager init log still shows a reasonable number of connections (should be within ±5 of the previous count; the narrow-strait count may increase by 1-5, which is expected)

---

## Regression Safety Notes

### Task 1 — Y-flattening
- **No regression risk:** The final tile-center waypoint was ALREADY Y-flattened (the `if isFinalTileDest` branch). This change extends the same behavior to all intermediate waypoints. Roblox humanoid physics handles elevation changes (stepping up curbs, descending gentle slopes) regardless of the MoveTo Y target.
- **Edge case to watch:** If any tile has internal ramps or stairs requiring active climbing, the humanoid might walk past instead of ascending. This is extremely unlikely for a flat Europe map game.

### Task 2 — Strait validation skip
- **No regression to land adjacencies:** The `classification ~= "strait"` check only affects pairs classified as `"strait"` by `_classifyCandidatePair`. All `"land"` classified pairs still go through `validateProofEndpoints` exactly as before.
- **Expected adjacency increase:** The narrow-strait connection count in the Phase 2 init log may increase by ~1-5 connections. These are legitimate adjacent tiles that were incorrectly rejected by the void-ratio check. This is the intended fix.
- **Why skipping is safe for straits:** `_classifyCandidatePair` already validates: water gap ≤ 5 studs, no cliff failures, multiple raycasts confirming land-water-land pattern, no intervening tiles (checked before classification). This is more thorough than `validateProofEndpoints`.

### Task 3 — Off-tile pathfinding validation
- **No regression to normal tiles:** For tiles where PathfindingService generates on-tile paths, the validation loop passes without clearing `arrivalPath`, and behavior is identical to before.
- **Trade-off for affected tiles:** Some arrival paths that previously used PathfindingService will now use cell-based BFS. BFS paths are grid-aligned (less smooth) but guaranteed to stay within the tile. Correctness (staying in-tile) is more important than smoothness.
- **The OBB check is generous:** `isPositionOnTile` uses the tile's full oriented bounding box, which is typically larger than the actual tile mesh. Only clearly off-tile waypoints (like the Sweden case at Z=302.7 vs tile Z-range [305.6, 319.9]) are caught.
