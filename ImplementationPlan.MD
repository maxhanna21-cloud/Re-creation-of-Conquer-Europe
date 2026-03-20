# TileAdjacencyManager v28: Evidence-Validated Adjacency

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate 240 false adjacencies (14.3% of all connections) by adding raycast-based endpoint validation and tightening the intervening tile threshold — without changing any existing thresholds or rearchitecting the pipeline.

**Architecture:** Two surgical changes to `ServerScriptService.TileAdjacencyManager`: (1) a new `validateProofEndpoints` function that raycasts at proof points to confirm they actually land on the claimed tiles, inserted as a final gate before any adjacency is accepted; (2) lowering the intervening tile detection threshold from >50% to ≥25% so that 3+ out of 9 samples finding a third tile blocks the pair.

**Tech Stack:** Luau, Roblox Workspace raycasts, existing TileAdjacencyManager raster pipeline

---

## File Structure

All changes are in a single file:

- **Modify:** `ServerScriptService.TileAdjacencyManager` (2508 lines)
  - Add new function `validateProofEndpoints` (~45 lines) near line 730 (after the edge-point helpers, before `isPathWalkable`)
  - Modify `hasInterveningTileBetween` at line 1182 (threshold change: 1 line)
  - Modify `calculateAdjacenciesFromFootprints` Phase 1 at lines 1241-1251 (wrap acceptance in validation gate)
  - Modify `calculateExtendedAdjacencies` Phase 2 at lines 1390-1397 (wrap acceptance in validation gate)
  - Modify `tryRepairAdjacencyPair` at lines 2356-2380 (wrap acceptance in validation gate)
  - Add a `rejectedReasons.endpoint` counter in both Phase 1 and Phase 2 stat tracking

No new files. No changes to NPCMovementSystem or any other script.

**Design decision:** `applyExplicitStraitConnections()` (line 2399) intentionally does NOT go through `validateProofEndpoints`. Explicit straits are manually curated in `STRAIT_CONNECTIONS` and always connect regardless of geometry. The validation gate only applies to the automatic pipeline (Phase 1 raster, Phase 2 extended, and runtime repair).

---

### Task 1: Add `validateProofEndpoints` function

**Files:**
- Modify: `ServerScriptService.TileAdjacencyManager` — insert new function after line 726 (after `getAABBEdge`, before the forward-declaration comment at line 728 / variable at line 729)

This is the core evidence gate. It raycasts downward at each proof endpoint to verify the point actually lands on the expected tile, then samples the path for excessive void.

- [ ] **Step 1: Add the validation function**

Insert the following function after the `getAABBEdge` helper (line 726). This goes before the `hasInterveningTileBetween` forward declaration:

```luau
-- Evidence gate: verify proof endpoints actually land on the claimed tiles.
-- Returns true if both endpoints raycast to their respective tiles and the path
-- is not void-dominated. Returns false (with reason string) if validation fails.
--
-- Small-tile fallback: if the raycast misses the expected tile but lands within
-- RASTER_CELL_SIZE of the tile's Position (XZ), accept with a warning.
-- This handles sub-cell tiles (e.g. Solrød Kommune at 0.9×0.6 studs) where
-- vertical raycasts can miss due to mesh precision.
local VOID_RATIO_REJECTION_THRESHOLD = 0.6  -- reject if >60% of path samples hit nothing
local ENDPOINT_PROXIMITY_FALLBACK = RASTER_CELL_SIZE  -- 2 studs — forgive endpoint miss if within this XZ distance of tile center

local function validateProofEndpoints(tileA, tileB, pointA, pointB)
	-- Raycast at pointA — should hit tileA
	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = { EUROPE_MAP }
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.IgnoreWater = true

	local hitA = Workspace:Raycast(Vector3.new(pointA.X, pointA.Y + 50, pointA.Z), Vector3.new(0, -100, 0), rayParams)
	local aValid = hitA and hitA.Instance == tileA
	if not aValid and hitA then
		-- Small-tile fallback: accept if hit is near tileA's center
		local dxA = pointA.X - tileA.Position.X
		local dzA = pointA.Z - tileA.Position.Z
		if math.sqrt(dxA * dxA + dzA * dzA) <= ENDPOINT_PROXIMITY_FALLBACK then
			aValid = true
		end
	end
	if not aValid then
		local hitName = hitA and hitA.Instance.Name or "VOID"
		return false, string.format("pointA hit %s instead of %s", hitName, tileA.Name)
	end

	-- Raycast at pointB — should hit tileB
	local hitB = Workspace:Raycast(Vector3.new(pointB.X, pointB.Y + 50, pointB.Z), Vector3.new(0, -100, 0), rayParams)
	local bValid = hitB and hitB.Instance == tileB
	if not bValid and hitB then
		local dxB = pointB.X - tileB.Position.X
		local dzB = pointB.Z - tileB.Position.Z
		if math.sqrt(dxB * dxB + dzB * dzB) <= ENDPOINT_PROXIMITY_FALLBACK then
			bValid = true
		end
	end
	if not bValid then
		local hitName = hitB and hitB.Instance.Name or "VOID"
		return false, string.format("pointB hit %s instead of %s", hitName, tileB.Name)
	end

	-- Void ratio check: sample 5 points along the path
	local voidCount = 0
	local totalSamples = 5
	for i = 1, totalSamples do
		local frac = i / (totalSamples + 1)
		local sampleX = pointA.X + (pointB.X - pointA.X) * frac
		local sampleZ = pointA.Z + (pointB.Z - pointA.Z) * frac
		local sampleHit = Workspace:Raycast(
			Vector3.new(sampleX, pointA.Y + 50, sampleZ),
			Vector3.new(0, -100, 0),
			rayParams
		)
		if not sampleHit then
			voidCount = voidCount + 1
		end
	end

	if voidCount / totalSamples > VOID_RATIO_REJECTION_THRESHOLD then
		return false, string.format("void-dominated path (%d/%d void)", voidCount, totalSamples)
	end

	return true, nil
end
```

- [ ] **Step 2: Verify the script parses**

Run the game briefly (Start → Stop) and check the output console for syntax errors. The new function is not yet called, so behavior should be unchanged.

- [ ] **Step 3: Commit**

```
git add -A && git commit -m "feat(adjacency): add validateProofEndpoints evidence gate function"
```

---

### Task 2: Lower the intervening tile threshold from >50% to ≥25%

**Files:**
- Modify: `ServerScriptService.TileAdjacencyManager:1182` — change the return condition

Currently line 1182 reads:
```luau
return interveningCount > (totalSamples / 2)
```

This requires MORE than 50% of samples (5+ out of 9) to find a third tile. Our audit showed the Midtjylland↔Sorø false adjacency had 4/9 = 44% intervening — just below threshold. Lowering to 25% means 3+ out of 9 samples blocks the pair.

- [ ] **Step 1: Change the threshold**

On line 1182, replace:
```luau
	return interveningCount > (totalSamples / 2)
```
with:
```luau
	return interveningCount >= math.ceil(totalSamples * 0.25)
```

Also update the comment on line 1147-1149 to reflect the new threshold:
```luau
-- Intervening tile detection using raster footprints.
-- Samples 9 fractions along the edge-to-edge path and checks CellToTilesMap.
-- Returns true if 25% or more of samples find a third tile between tileA and tileB.
```

- [ ] **Step 2: Verify parse**

Start → Stop the game. Check console for errors. No behavioral test yet — the threshold change affects Phase 2 which runs at init.

- [ ] **Step 3: Commit**

```
git add -A && git commit -m "fix(adjacency): lower intervening tile threshold from >50% to >=25%"
```

---

### Task 3: Wire the validation gate into Phase 1 (calculateAdjacenciesFromFootprints)

**Files:**
- Modify: `ServerScriptService.TileAdjacencyManager:1241-1262` — wrap the acceptance block

Phase 1 accepts adjacency at lines 1241-1255 after `_classifyCandidatePair` returns a classification. We need to validate the crossing endpoints before accepting.

- [ ] **Step 1: Add validation gate and endpoint rejection counter**

First, add an `endpoint` counter to the `rejected` table at line 1210. Change:
```luau
	local rejected = { distance = 0, unwalkable = 0 }
```
to:
```luau
	local rejected = { distance = 0, unwalkable = 0, endpoint = 0 }
```

Then, replace lines 1241-1262 (the full `if classification and crossing then ... else ... end` block) with:

```luau
								if classification and crossing then
									-- Evidence gate: validate proof endpoints hit the correct tiles
									local epValid, epReason = validateProofEndpoints(tileA, tileB, crossing.pointA, crossing.pointB)
									if epValid then
										local proofMode = (classification == "strait") and "strait" or "raster"

										table.insert(AdjacentTiles[tileA], tileB)
										if not AdjacentTiles[tileB] then AdjacentTiles[tileB] = {} end
										table.insert(AdjacentTiles[tileB], tileA)

										if not AdjacencyProof[tileA] then AdjacencyProof[tileA] = {} end
										if not AdjacencyProof[tileB] then AdjacencyProof[tileB] = {} end
										AdjacencyProof[tileA][tileB] = { mode = proofMode, pointA = crossing.pointA, pointB = crossing.pointB, distance = crossing.distance }
										AdjacencyProof[tileB][tileA] = { mode = proofMode, pointA = crossing.pointB, pointB = crossing.pointA, distance = crossing.distance }

										if proofMode == "strait" then
											narrowStraitAcceptedCount = narrowStraitAcceptedCount + 1
										end
									else
										rejected.endpoint = rejected.endpoint + 1
										if DEBUG_REJECTED_ADJACENCY then
											print(string.format("[TileAdjacencyManager] Raster pair rejected (endpoint validation): %s <-> %s (%s)",
												tileA.Name, tileB.Name, epReason or "unknown"))
										end
									end
								else
									rejected.unwalkable = rejected.unwalkable + 1
									if DEBUG_REJECTED_ADJACENCY then
										print(string.format("[TileAdjacencyManager] Raster pair rejected (no land crossing; no narrow strait): %s <-> %s (edgeDist: %.1f)",
											tileA.Name, tileB.Name, edgeDist))
									end
								end
```

**Important:** This replaces the entire `if classification ... else ... end` block (lines 1241-1262). The existing `else` branch for `rejected.unwalkable` (lines 1256-1262) is preserved in the replacement.

Finally, update the stats print at line 1286 to include the endpoint counter. Change:
```luau
	print(string.format("[TileAdjacencyManager] Rasterization adjacency complete: %d connections, avg %.1f per tile (rejected: distance=%d, unwalkable=%d, narrow-strait=%d)",
		totalConnections, avgConnections, rejected.distance, rejected.unwalkable, narrowStraitAcceptedCount))
```
to:
```luau
	print(string.format("[TileAdjacencyManager] Rasterization adjacency complete: %d connections, avg %.1f per tile (rejected: distance=%d, unwalkable=%d, endpoint=%d, narrow-strait=%d)",
		totalConnections, avgConnections, rejected.distance, rejected.unwalkable, rejected.endpoint, narrowStraitAcceptedCount))
```

- [ ] **Step 2: Start the game and check Phase 1 output**

Start the game. In the console output, look for:
```
[TileAdjacencyManager] Rasterization adjacency complete: X connections ...
```
Verify the `endpoint=` counter is present and shows rejections. The total connection count should be lower than the previous ~1694.

- [ ] **Step 3: Commit**

```
git add -A && git commit -m "fix(adjacency): wire endpoint validation into Phase 1 raster adjacency"
```

---

### Task 4: Wire the validation gate into Phase 2 (calculateExtendedAdjacencies)

**Files:**
- Modify: `ServerScriptService.TileAdjacencyManager:1315-1431` — add endpoint rejection counter and wrap acceptance

- [ ] **Step 1: Add endpoint counter and validation gate**

Add `endpoint = 0` to the `rejectedReasons` table at line 1315-1318. Change:
```luau
	local rejectedReasons = {
		intervening = 0,
		unwalkable = 0,
	}
```
to:
```luau
	local rejectedReasons = {
		intervening = 0,
		unwalkable = 0,
		endpoint = 0,
	}
```

Then, wrap the acceptance block at lines 1390-1410. Replace:
```luau
			local classification, crossing = _classifyCandidatePair(tileA, tileB, DEFAULT_CANDIDATE_K, "raster")
			if classification and crossing then
				local proofMode = (classification == "strait") and "strait" or "raster"
				shouldConnect = true

				if not AdjacencyProof[tileA] then AdjacencyProof[tileA] = {} end
				if not AdjacencyProof[tileB] then AdjacencyProof[tileB] = {} end
				AdjacencyProof[tileA][tileB] = { mode = proofMode, pointA = crossing.pointA, pointB = crossing.pointB, distance = crossing.distance }
				AdjacencyProof[tileB][tileA] = { mode = proofMode, pointA = crossing.pointB, pointB = crossing.pointA, distance = crossing.distance }

				if proofMode == "strait" then
					narrowStraitAcceptedCount = narrowStraitAcceptedCount + 1
					if DEBUG_EXTENDED_ADJACENCY or DEBUG_REJECTED_ADJACENCY then
						local gapText = crossing.waterGapStuds and string.format("%.1f", crossing.waterGapStuds) or "?"
						print(string.format("[TileAdjacencyManager] Narrow-strait adjacency: %s <-> %s (segment: %.1f, water gap: %s)",
							tileA.Name, tileB.Name, crossing.distance, gapText))
					end
				end
			else
				rejectedCount = rejectedCount + 1
				rejectedReasons.unwalkable = rejectedReasons.unwalkable + 1
			end
```

with:

```luau
			local classification, crossing = _classifyCandidatePair(tileA, tileB, DEFAULT_CANDIDATE_K, "raster")
			if classification and crossing then
				-- Evidence gate: validate proof endpoints hit the correct tiles
				local epValid, epReason = validateProofEndpoints(tileA, tileB, crossing.pointA, crossing.pointB)
				if epValid then
					local proofMode = (classification == "strait") and "strait" or "raster"
					shouldConnect = true

					if not AdjacencyProof[tileA] then AdjacencyProof[tileA] = {} end
					if not AdjacencyProof[tileB] then AdjacencyProof[tileB] = {} end
					AdjacencyProof[tileA][tileB] = { mode = proofMode, pointA = crossing.pointA, pointB = crossing.pointB, distance = crossing.distance }
					AdjacencyProof[tileB][tileA] = { mode = proofMode, pointA = crossing.pointB, pointB = crossing.pointA, distance = crossing.distance }

					if proofMode == "strait" then
						narrowStraitAcceptedCount = narrowStraitAcceptedCount + 1
						if DEBUG_EXTENDED_ADJACENCY or DEBUG_REJECTED_ADJACENCY then
							local gapText = crossing.waterGapStuds and string.format("%.1f", crossing.waterGapStuds) or "?"
							print(string.format("[TileAdjacencyManager] Narrow-strait adjacency: %s <-> %s (segment: %.1f, water gap: %s)",
								tileA.Name, tileB.Name, crossing.distance, gapText))
						end
					end
				else
					rejectedCount = rejectedCount + 1
					rejectedReasons.endpoint = rejectedReasons.endpoint + 1
					if DEBUG_REJECTED_ADJACENCY then
						print(string.format("[TileAdjacencyManager] Extended rejected (endpoint validation): %s <-> %s (%s)",
							tileA.Name, tileB.Name, epReason or "unknown"))
					end
				end
			else
				rejectedCount = rejectedCount + 1
				rejectedReasons.unwalkable = rejectedReasons.unwalkable + 1
			end
```

Update the stats print at line 1429 to include `endpoint`. Change:
```luau
	print(string.format("[TileAdjacencyManager] Extended adjacency: added %d connections, rejected %d (intervening=%d, unwalkable=%d, narrow-strait=%d)",
		extendedCount, rejectedCount,
		rejectedReasons.intervening, rejectedReasons.unwalkable, narrowStraitAcceptedCount))
```
to:
```luau
	print(string.format("[TileAdjacencyManager] Extended adjacency: added %d connections, rejected %d (intervening=%d, unwalkable=%d, endpoint=%d, narrow-strait=%d)",
		extendedCount, rejectedCount,
		rejectedReasons.intervening, rejectedReasons.unwalkable, rejectedReasons.endpoint, narrowStraitAcceptedCount))
```

- [ ] **Step 2: Start the game and check Phase 2 output**

Start the game. In the console output, look for:
```
[TileAdjacencyManager] Extended adjacency: added X connections, rejected Y (intervening=..., unwalkable=..., endpoint=..., narrow-strait=...)
```
Verify `endpoint=` shows rejections. The extended adjacency count should be noticeably lower.

- [ ] **Step 3: Commit**

```
git add -A && git commit -m "fix(adjacency): wire endpoint validation into Phase 2 extended adjacency"
```

---

### Task 5: Wire the validation gate into tryRepairAdjacencyPair

**Files:**
- Modify: `ServerScriptService.TileAdjacencyManager:2356-2380`

The runtime repair function must also validate endpoints, otherwise a runtime repair could re-introduce a false adjacency that the init pipeline correctly rejected.

- [ ] **Step 1: Add validation to both repair paths**

Replace lines 2356-2380 (from the Phase 1 parity raster check through the final `ensureAdjacencyAndProof` call):

```luau
	-- Phase 1 parity: raster-adjacent with walkability
	if sharesRasterNeighborCell(tileA, tileB) and rasterEdgeDistance <= MAX_RASTER_ADJACENCY_DISTANCE then
		local bestCrossing = _getBestWalkableBorderCrossing(tileA, tileB, DEFAULT_CANDIDATE_K, "raster")
		if bestCrossing then
			local epValid = validateProofEndpoints(tileA, tileB, bestCrossing.pointA, bestCrossing.pointB)
			if epValid then
				crossing = bestCrossing
				mode = "raster"
			end
		end
	end

	-- Phase 2 parity: extended (intervening check + evidence-first classification)
	if not crossing and rasterEdgeDistance > 0 and rasterEdgeDistance <= NARROW_STRAIT_THRESHOLD then
		local hasIntervening = hasInterveningTileBetween(tileA, tileB, lookup)
		if not hasIntervening then
			local classification, classifyCrossing = _classifyCandidatePair(tileA, tileB, DEFAULT_CANDIDATE_K, "raster")
			if classification and classifyCrossing then
				local epValid = validateProofEndpoints(tileA, tileB, classifyCrossing.pointA, classifyCrossing.pointB)
				if epValid then
					crossing = classifyCrossing
					mode = (classification == "strait") and "strait" or "raster"
				end
			end
		end
	end

	if not crossing or not mode then
		return false
	end

	return ensureAdjacencyAndProof(tileA, tileB, mode, crossing)
```

- [ ] **Step 2: Verify parse — Start → Stop game**

- [ ] **Step 3: Commit**

```
git add -A && git commit -m "fix(adjacency): wire endpoint validation into tryRepairAdjacencyPair"
```

---

### Task 6: Run the map-wide adjacency audit

**Files:** None (runtime diagnostic only)

This is the acceptance test. Run the same audit from our investigation to measure improvement.

- [ ] **Step 1: Start the game and run the audit script**

Execute this Luau in the command bar or via MCP `execute_luau`:

```luau
local TAM = require(game.ServerScriptService.TileAdjacencyManager)
local europeMap = workspace:FindFirstChild("EuropeMap")

local falseAdj = 0
local trueAdj = 0
local checked = {}

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Include
params.FilterDescendantsInstances = {europeMap}

for _, country in ipairs(europeMap:GetChildren()) do
	if not country:IsA("Model") then continue end
	for _, tile in ipairs(country:GetChildren()) do
		if not tile:IsA("BasePart") then continue end
		local ok, adj = pcall(TAM.getAdjacentTiles, tile)
		if not ok or type(adj) ~= "table" then continue end
		for _, neighbor in ipairs(adj) do
			local pairKey = tile.Name < neighbor.Name
				and (tile.Name .. "|" .. neighbor.Name)
				or (neighbor.Name .. "|" .. tile.Name)
			if checked[pairKey] then continue end
			checked[pairKey] = true
			local ok2, proof = pcall(TAM.getAdjacencyProof, tile, neighbor)
			if not ok2 or not proof or not proof.pointA or not proof.pointB then continue end
			local midX = (proof.pointA.X + proof.pointB.X) / 2
			local midZ = (proof.pointA.Z + proof.pointB.Z) / 2
			local ray = workspace:Raycast(Vector3.new(midX, 20, midZ), Vector3.new(0, -40, 0), params)
			local isFalse = false
			if ray then
				if ray.Instance ~= tile and ray.Instance ~= neighbor then
					isFalse = true
				end
			else
				local rayA = workspace:Raycast(Vector3.new(proof.pointA.X, 20, proof.pointA.Z), Vector3.new(0, -40, 0), params)
				local rayB = workspace:Raycast(Vector3.new(proof.pointB.X, 20, proof.pointB.Z), Vector3.new(0, -40, 0), params)
				local hitA = rayA and (rayA.Instance == tile or rayA.Instance == neighbor)
				local hitB = rayB and (rayB.Instance == tile or rayB.Instance == neighbor)
				if not hitA and not hitB then isFalse = true end
			end
			if isFalse then falseAdj += 1 else trueAdj += 1 end
		end
	end
end

local total = falseAdj + trueAdj
return string.format("AUDIT: %d total, %d true (%.1f%%), %d false (%.1f%%)",
	total, trueAdj, trueAdj/total*100, falseAdj, falseAdj/total*100)
```

- [ ] **Step 2: Verify results**

**Expected (before):** 1674 total, 1434 true (85.7%), 240 false (14.3%)

**Expected (after):** False adjacencies should drop to <30 (under 2%). The total connection count will also drop because the endpoint gate rejects bad pairs.

If false adjacencies are still above 5%, investigate which pairs are slipping through and consider whether `VOID_RATIO_REJECTION_THRESHOLD` (0.6) needs tightening.

- [ ] **Step 3: Spot-check Denmark specifically**

Run this focused check on Denmark, the worst offender:

```luau
local TAM = require(game.ServerScriptService.TileAdjacencyManager)
local dk = workspace.EuropeMap.Denmark
local result = ""
for _, tile in ipairs(dk:GetChildren()) do
	if not tile:IsA("BasePart") then continue end
	local ok, adj = pcall(TAM.getAdjacentTiles, tile)
	if ok and type(adj) == "table" then
		local names = {}
		for _, n in ipairs(adj) do table.insert(names, n.Name) end
		result ..= tile.Name .. ": " .. #adj .. " -> " .. table.concat(names, ", ") .. "\n"
	end
end
return result
```

Verify:
- Region Midtjylland should NOT be adjacent to Sorø, Kalundborg, Odsherred, or Holbæk (those are on Zealand, across the Great Belt)
- Lolland Kommune should NOT be adjacent to Mecklenburg-Vorpommern or Schleswig-Holstein (unless via STRAIT_CONNECTIONS)
- Bornholms Kommune should still have 0 adjacencies (isolated island — expected)

- [ ] **Step 4: Commit any adjustments, or confirm success**

If all checks pass, no code changes needed. If thresholds need tuning, adjust `VOID_RATIO_REJECTION_THRESHOLD` or `ENDPOINT_PROXIMITY_FALLBACK` and re-run.

```
git add -A && git commit -m "test(adjacency): verify v28 evidence gate reduces false adjacencies"
```

---

### Task 7: Run the game and verify NPC movement

**Files:** None (gameplay verification)

- [ ] **Step 1: Start a full play session**

Start the game and let NPCs run for 30-60 seconds. Watch the console for:
- `[NPCMovementSystem]` errors about invalid tiles or fall recovery
- `[TileAdjacencyManager]` warnings about endpoint validation failures

- [ ] **Step 2: Verify no NPCs fall off the map in Denmark/Switzerland**

Navigate to Denmark in-game. Watch NPCs moving between tiles. They should follow land paths and not teleport across water between islands.

- [ ] **Step 3: Verify explicit straits still work**

Check that the Schleswig-Holstein ↔ Lolland Kommune explicit strait (from `STRAIT_CONNECTIONS`) still functions. NPCs should be able to cross this strait since it's explicitly declared and bypasses the automatic pipeline.

- [ ] **Step 4: Final commit**

```
git add -A && git commit -m "v28: evidence-validated adjacency pipeline — 240 false adjacencies eliminated"
```
