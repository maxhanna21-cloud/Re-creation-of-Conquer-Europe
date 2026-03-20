# TileAdjacencyManager v27: Evidence-First Adjacency Pipeline

## What This Plan Fixes

Two bugs in `TileAdjacencyManager.luau`:

1. **Denmark false positives**: NPCs travel overland between Danish islands (e.g., Jutland → Zealand) because the system auto-connects tiles separated by open sea. The current Phase 2 code accepts ALL tile pairs between 3-8 studs apart without checking if there is actually walkable ground or a narrow strait between them. Over open water, the only gate (`hasInterveningTileBetween`) returns false because there are no raster cells in the ocean, so every cross-sea pair passes.

2. **Crimea false negative**: Players cannot move troops from Crimea (`кримська область`) to Krasnodar (`Краснода́рский край`) across the Kerch Strait. The tiles share raster boundary cells (0.13 stud raster edge distance), so Phase 1 processes them. Phase 1 requires land walkability proof. The walkability check fails because the Kerch Strait water gap causes consecutive raycast misses. Phase 2 then skips them because their raster edge distance (0.13 studs) puts them in the "close pair" branch, which also requires walkability. Result: the pair is rejected everywhere.

## Root Cause (Shared)

The current code uses **distance thresholds as semantic classifiers**:
- Distance ≤ 3 studs → "must be a land connection" → require walkability
- Distance 3-8 studs → "must be a water crossing" → accept without walkability

This is backwards. Distance should decide **which pairs to examine** (candidacy), not **what kind of connection they are** (classification). Evidence from raycasts should determine the connection type.

## The Fix: Evidence-First Pipeline

Instead of branching on distance, we classify every candidate pair using **evidence**:

1. Try walkability (raycast ground coverage). If it passes → **land connection**.
2. If walkability fails, check WHY it failed. If the failure is due to a narrow water gap (≤ 5 studs of consecutive raycast misses) and NOT a cliff → **strait connection**.
3. If the water gap is too wide (> 5 studs), or the failure is a cliff/bad terrain → **reject**.

This fixes both bugs:
- **Denmark**: Cross-sea pairs fail walkability with a WIDE water gap (5.6+ studs) → exceeds the 5-stud threshold → rejected.
- **Crimea**: Kerch Strait fails walkability with a NARROW water gap (1.2 studs at the narrowest point) → within the 5-stud threshold → accepted as strait.

---

## Files To Modify

Modify **only** this file:

1. `src/shared/TileAdjacencyManager.luau`

Do **not** modify any other file. The `NPCMovementSystem.luau` already handles `proof.mode == "strait"` correctly (verified: lines 600-605 trust strait proofs directly without re-validating walkability).

---

## Important Design Rules

These rules are **part of the implementation**, not optional commentary.

### Rule 1: `isPathWalkable` reports diagnostics, but does NOT classify

It may return:
- water gap estimate
- cliff flag
- failure reason

But it does **not** decide land vs strait. That decision belongs in `_classifyCandidatePair`.

### Rule 2: `_getBestWalkableBorderCrossing` remains unchanged

It still does only one job: finding a true walkable crossing. No strait logic goes into that function.

### Rule 3: `hasInterveningTileBetween` remains unchanged

It is still only a veto/pre-filter. If there is an intervening tile, block. If not, that does NOT prove the pair should connect.

### Rule 4: `EXTENDED_ADJACENCY_THRESHOLD` stays defined

Do not remove the constant. The new pipeline no longer uses it for semantic branching, but it remains for compatibility and historical continuity.

### Rule 5: The ONLY new helper function is `_classifyCandidatePair`

Do not create additional helper functions.

### Rule 6: Strait classification must NOT depend only on `reason == "water_gap"`

A valid narrow strait may fail land walkability through consecutive misses, midpoint failure, or low ratio. The true signal is: **non-cliff failure** with a **narrow measured water gap** (waterGapStuds > 0 and ≤ MAX_STRAIT_WATER_GAP).

### Rule 7: Strait fallback must examine multiple candidate edge segments

Do not probe only the single closest edge point. Use multiple candidate edge points so the classifier is not brittle against local coastline geometry.

---

## What NOT To Change

Do **not** change any of the following:

- `RASTER_CELL_SIZE`
- `MAX_RASTER_ADJACENCY_DISTANCE`
- `EXTENDED_ADJACENCY_THRESHOLD` (keep the constant, but it is no longer used for branching — see Step 5)
- `GROUND_RATIO_THRESHOLD`
- `MAX_CONSECUTIVE_MISSES`
- `NARROW_STRAIT_THRESHOLD`
- `scanAllTiles()`
- `rasterizeTile()` / `rasterizeAllTiles()`
- `hasInterveningTileBetween()` — do not change its logic or signature
- `findClosestEdgePoints()` / `findClosestEdgePointsBBox()`
- `_findCandidateEdgePoints()` / `_findCandidateEdgePointsBBox()`
- `_getBestWalkableBorderCrossing()` — do not change its logic or signature
- `findNearestSurfacePoint()`
- `calculateSafeCenters()`
- `findCellPath()`
- `applyExplicitStraitConnections()` — do not change its logic (it already stores `mode = "strait"`)
- `sharesRasterNeighborCell()` — do not change (already correct)
- Init order at the bottom of the file
- Any public function name
- `NPCMovementSystem.luau` — already handles strait proofs correctly

---

## Implementation Steps

Perform these steps in the exact order listed. Each step builds on the previous one.

### Step 1: Add the `MAX_STRAIT_WATER_GAP` constant

**File:** `src/shared/TileAdjacencyManager.luau`

**Location:** After the `NARROW_STRAIT_THRESHOLD` constant block (after line 54, near the other threshold constants).

**Add this constant:**

```lua
-- Maximum measured water-gap width (in studs) that qualifies as an automatic strait.
-- Measured as: maxConsecutiveMisses * stepSize during the walkability raycast probe.
-- Gaps wider than this are open sea and will be rejected (unless in STRAIT_CONNECTIONS).
-- Tuned from real map measurements:
--   Kerch Strait (Crimea<->Krasnodar): 1.2 studs (accepted)
--   Little Belt (Jutland<->Funen): 2.8 studs (accepted)
--   Great Belt (Funen<->Zealand): 4.0 studs (accepted)
--   Open sea (Jutland<->Zealand): 5.6 studs (rejected)
local MAX_STRAIT_WATER_GAP = 5
```

Do **not** change any existing constant. Just add this new one after the existing block.

---

### Step 2: Modify `isPathWalkable` to return diagnostics

**File:** `src/shared/TileAdjacencyManager.luau`

**Function:** `isPathWalkable` (starts at line 707)

**What to change:** Add a second return value (a diagnostics table) to every `return false` and `return true` statement, accept an optional `opts.maxDistance` override, and always compute `waterGapStuds` after the raycast loop. Existing callers only read the first return value, so this is backward compatible.

**2A: Add `maxDistance` override support**

Find this code (around line 725-726):

```lua
	local maxDistance = MAX_RASTER_ADJACENCY_DISTANCE
	if edgeDist > maxDistance then
```

Replace with:

```lua
	local maxDistance = opts.maxDistance or MAX_RASTER_ADJACENCY_DISTANCE
	if edgeDist > maxDistance then
```

This allows callers to pass `opts.maxDistance = NARROW_STRAIT_THRESHOLD` to probe wider gaps for strait detection.

**2B: Add diagnostics to the distance rejection return**

Find this code (around line 735):

```lua
		return false
	end
```

(This is the `return false` inside the `if edgeDist > maxDistance then` block, after the two debug print statements.)

Replace with:

```lua
		return false, { reason = "too_far", waterGapStuds = 0, failedDueToCliff = false }
	end
```

**2C: Add diagnostics to the cliff rejection return**

Find this code (around line 801-802):

```lua
	if failedDueToCliff then
		return false
	end
```

Replace with:

```lua
	if failedDueToCliff then
		return false, { reason = "cliff", waterGapStuds = 0, failedDueToCliff = true }
	end
```

**2D: Compute `waterGapStuds` BEFORE the consecutive-misses check**

Find the consecutive-misses check block (around line 805). **Insert these two lines BEFORE the `if maxConsecutiveMisses > MAX_CONSECUTIVE_MISSES then` check:**

```lua
	local stepSize = edgeDist / math.max(1, numChecks)
	local waterGapStuds = maxConsecutiveMisses * stepSize
```

This ensures `waterGapStuds` is available for ALL subsequent return paths, not just the water_gap one.

**2E: Add diagnostics to the consecutive-misses rejection return**

Find this code (around line 805-811):

```lua
	if maxConsecutiveMisses > MAX_CONSECUTIVE_MISSES then
		if DEBUG_REJECTED_ADJACENCY then
			print(string.format("[TileAdjacencyManager] Rejected (WATER): %s <-> %s (%d consecutive misses, distance: %.1f)",
				tileA.Name, tileB.Name, maxConsecutiveMisses, edgeDist))
		end
		return false
	end
```

Replace with:

```lua
	if maxConsecutiveMisses > MAX_CONSECUTIVE_MISSES then
		if DEBUG_REJECTED_ADJACENCY then
			print(string.format("[TileAdjacencyManager] Rejected (WATER): %s <-> %s (%d consecutive misses, gap: %.1f studs, distance: %.1f)",
				tileA.Name, tileB.Name, maxConsecutiveMisses, waterGapStuds, edgeDist))
		end
		return false, { reason = "water_gap", waterGapStuds = waterGapStuds, failedDueToCliff = false }
	end
```

**2F: Add diagnostics to the midpoint rejection return**

Find this code (around line 823-829):

```lua
		if midGroundCount < 2 then
			if DEBUG_REJECTED_ADJACENCY then
				print(string.format("[TileAdjacencyManager] Rejected (MID-WATER): %s <-> %s (only %d/3 middle points have ground)",
					tileA.Name, tileB.Name, midGroundCount))
			end
			return false
		end
```

Replace with:

```lua
		if midGroundCount < 2 then
			if DEBUG_REJECTED_ADJACENCY then
				print(string.format("[TileAdjacencyManager] Rejected (MID-WATER): %s <-> %s (only %d/3 middle points have ground)",
					tileA.Name, tileB.Name, midGroundCount))
			end
			return false, { reason = "midpoint", waterGapStuds = waterGapStuds, failedDueToCliff = false }
		end
```

**2G: Add diagnostics to the ground-ratio return and the success return**

Find this code (around line 832-845):

```lua
	local groundRatio = groundCount / totalChecks
	local isWalkable = groundRatio >= GROUND_RATIO_THRESHOLD

	if DEBUG_REJECTED_ADJACENCY and not isWalkable then
		print(string.format("[TileAdjacencyManager:Runtime] Walkability failed: %s <-> %s (edgeDist: %.1f, groundRatio: %.2f, consecutiveMisses: %d, mode: %s)",
			tileA.Name, tileB.Name, edgeDist, groundRatio, maxConsecutiveMisses, mode))
	end

	if DEBUG_EXTENDED_ADJACENCY and isWalkable then
		print(string.format("[TileAdjacencyManager] Accepted: %s <-> %s (ground ratio: %.0f%%, distance: %.1f, mode: %s)",
			tileA.Name, tileB.Name, groundRatio * 100, edgeDist, mode))
	end

	return isWalkable
```

Replace with:

```lua
	local groundRatio = groundCount / totalChecks
	local isWalkable = groundRatio >= GROUND_RATIO_THRESHOLD

	if DEBUG_REJECTED_ADJACENCY and not isWalkable then
		print(string.format("[TileAdjacencyManager:Runtime] Walkability failed: %s <-> %s (edgeDist: %.1f, groundRatio: %.2f, consecutiveMisses: %d, mode: %s)",
			tileA.Name, tileB.Name, edgeDist, groundRatio, maxConsecutiveMisses, mode))
	end

	if DEBUG_EXTENDED_ADJACENCY and isWalkable then
		print(string.format("[TileAdjacencyManager] Accepted: %s <-> %s (ground ratio: %.0f%%, distance: %.1f, mode: %s)",
			tileA.Name, tileB.Name, groundRatio * 100, edgeDist, mode))
	end

	if isWalkable then
		return true, { reason = nil, waterGapStuds = waterGapStuds, failedDueToCliff = false }
	else
		return false, { reason = "low_ratio", waterGapStuds = waterGapStuds, failedDueToCliff = false }
	end
```

**Summary of `isPathWalkable` changes:**
- Accepts `opts.maxDistance` (optional, defaults to `MAX_RASTER_ADJACENCY_DISTANCE`)
- Every return now includes a diagnostics table: `{ reason: string?, waterGapStuds: number, failedDueToCliff: boolean }`
- `waterGapStuds` is computed ONCE after the raycast loop and included in ALL subsequent returns
- `failedDueToCliff` is true ONLY for cliff failures, false otherwise
- Existing callers are unaffected (they ignore the second return value)

---

### Step 3: Add the `_classifyCandidatePair` helper function

**File:** `src/shared/TileAdjacencyManager.luau`

**Location:** Place this function AFTER `_getBestWalkableBorderCrossing` (which ends around line 895) and BEFORE `calculateAdjacenciesFromFootprints` (which starts around line 1056). A good spot is around line 900.

**Add this entire function:**

```lua
-- Evidence-first candidate pair classifier.
-- Distance creates candidacy; raycast evidence creates meaning.
--
-- Returns two values:
--   classification: "land" or "strait" or nil (rejected)
--   crossing: { pointA: Vector3, pointB: Vector3, distance: number } or nil
--
-- Logic:
--   1. If within walkability range, try multi-candidate walkable crossing search (land).
--   2. If land fails, probe multiple candidate edge segments for narrow water gap (strait).
--   3. Accept strait only if: non-cliff failure AND waterGapStuds > 0 AND waterGapStuds <= MAX_STRAIT_WATER_GAP.
--   4. Pick the candidate with the narrowest water gap.
--   5. Otherwise, reject.
local function _classifyCandidatePair(tileA, tileB, candidateK, mode)
	local ptA, ptB, edgeDist = findClosestEdgePoints(tileA, tileB)
	if not ptA or not ptB then
		return nil, nil
	end

	-- Step 1: If within standard walkability range, try to find a walkable crossing (land connection).
	-- _getBestWalkableBorderCrossing tries multiple candidate edge points and returns the first walkable one.
	-- It internally calls isPathWalkable which has a MAX_RASTER_ADJACENCY_DISTANCE limit (6 studs).
	if edgeDist <= MAX_RASTER_ADJACENCY_DISTANCE then
		local bestCrossing = _getBestWalkableBorderCrossing(tileA, tileB, candidateK, mode)
		if bestCrossing then
			return "land", bestCrossing
		end
	end

	-- Step 2: Land walkability failed or edge distance exceeds walkability range.
	-- Probe MULTIPLE candidate edge segments for narrow water gap (strait detection).
	-- Using multiple candidates prevents brittleness against irregular coastline geometry.
	local candidates = _findCandidateEdgePoints(tileA, tileB, candidateK)
	if not candidates or #candidates == 0 then
		-- Fallback: use the closest edge point pair if no candidates were found
		candidates = {
			{ pointA = ptA, pointB = ptB, distance = edgeDist },
		}
	end

	local bestStraitCrossing = nil
	local bestStraitGap = nil

	for _, candidate in ipairs(candidates) do
		local candidateDist = candidate.distance
		if candidate.pointA and candidate.pointB
			and candidateDist
			and candidateDist > 0
			and candidateDist <= NARROW_STRAIT_THRESHOLD then

			local walkable, diagnostics = isPathWalkable(tileA, tileB, {
				mode = mode,
				pointA = candidate.pointA,
				pointB = candidate.pointB,
				distance = candidateDist,
				maxDistance = NARROW_STRAIT_THRESHOLD,
			})

			-- If a candidate unexpectedly passes walkability, treat it as land.
			if walkable then
				return "land", {
					pointA = candidate.pointA,
					pointB = candidate.pointB,
					distance = candidateDist,
				}
			end

			-- Check if this failure looks like a narrow water crossing.
			-- Accept strait only if: NOT a cliff, AND water gap is measurable and narrow enough.
			local isCliff = diagnostics and diagnostics.failedDueToCliff
			local gapStuds = diagnostics and diagnostics.waterGapStuds or 0

			if not isCliff
				and gapStuds > 0
				and gapStuds <= MAX_STRAIT_WATER_GAP then
				-- Track the candidate with the narrowest water gap
				if not bestStraitGap or gapStuds < bestStraitGap then
					bestStraitGap = gapStuds
					bestStraitCrossing = {
						pointA = candidate.pointA,
						pointB = candidate.pointB,
						distance = candidateDist,
						waterGapStuds = gapStuds,
					}
				end
			end
		end
	end

	-- Step 3: If any candidate had a valid narrow water gap, accept as strait.
	if bestStraitCrossing then
		return "strait", bestStraitCrossing
	end

	-- Step 4: Not walkable land and not a narrow strait. Reject.
	return nil, nil
end
```

**Important:** This function must be placed AFTER these functions are defined (it calls them):
- `findClosestEdgePoints`
- `_findCandidateEdgePoints`
- `_getBestWalkableBorderCrossing`
- `isPathWalkable`

And BEFORE these functions that will call it:
- `calculateAdjacenciesFromFootprints`
- `calculateExtendedAdjacencies`

**Key design choices in this function:**
- **Multi-candidate probing**: Tries all K candidate edge segments, not just the closest. This prevents missing the narrowest crossing point on irregular coastlines.
- **Non-cliff gate**: Cliff failures are never accepted as straits (different failure mode).
- **waterGapStuds > 0 gate**: Zero gap means no water was detected — that is not a strait.
- **Narrowest-gap selection**: If multiple candidates qualify, picks the one with the smallest water gap for the most accurate crossing path.
- **Unexpected walkability**: If a candidate passes walkability during the strait probe, returns "land" immediately (this can happen when `_getBestWalkableBorderCrossing` missed it due to surface correction differences).

---

### Step 4: Update Phase 1 (`calculateAdjacenciesFromFootprints`) to use evidence-first classification

**File:** `src/shared/TileAdjacencyManager.luau`

**Function:** `calculateAdjacenciesFromFootprints` (starts at line 1056)

**What to change:** Replace the land-only walkability check with `_classifyCandidatePair` so Phase 1 can detect both land connections AND strait crossings for tiles that share raster cells.

Find this block (lines 1107-1127):

```lua
							if edgeDist <= MAX_RASTER_ADJACENCY_DISTANCE then
									-- Phase 1: Raster-adjacent pairs require walkability proof.
									-- Shared cardinal-neighbor cells confirm physical proximity,
									-- but walkability is required to reject water-separated pairs.
									local bestCrossing = _getBestWalkableBorderCrossing(tileA, tileB, DEFAULT_CANDIDATE_K, "raster")
									if bestCrossing then
										table.insert(AdjacentTiles[tileA], tileB)
										if not AdjacentTiles[tileB] then AdjacentTiles[tileB] = {} end
										table.insert(AdjacentTiles[tileB], tileA)

										if not AdjacencyProof[tileA] then AdjacencyProof[tileA] = {} end
										if not AdjacencyProof[tileB] then AdjacencyProof[tileB] = {} end
										AdjacencyProof[tileA][tileB] = { mode = "raster", pointA = bestCrossing.pointA, pointB = bestCrossing.pointB, distance = bestCrossing.distance }
										AdjacencyProof[tileB][tileA] = { mode = "raster", pointA = bestCrossing.pointB, pointB = bestCrossing.pointA, distance = bestCrossing.distance }
									else
										rejected.unwalkable = rejected.unwalkable + 1
										if DEBUG_REJECTED_ADJACENCY then
											print(string.format("[TileAdjacencyManager] Raster pair rejected (unwalkable): %s <-> %s (edgeDist: %.1f)",
												tileA.Name, tileB.Name, edgeDist))
										end
									end
```

Replace with:

```lua
							if edgeDist <= MAX_RASTER_ADJACENCY_DISTANCE then
									-- Phase 1: Raster-adjacent pairs. Use evidence-first classification:
									-- try walkability first (land), then probe for narrow strait if walkability fails.
									local classification, crossing = _classifyCandidatePair(tileA, tileB, DEFAULT_CANDIDATE_K, "raster")
									if classification and crossing then
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
										rejected.unwalkable = rejected.unwalkable + 1
										if DEBUG_REJECTED_ADJACENCY then
											print(string.format("[TileAdjacencyManager] Raster pair rejected (no land crossing; no narrow strait): %s <-> %s (edgeDist: %.1f)",
												tileA.Name, tileB.Name, edgeDist))
										end
									end
```

**What this changes:**
- Before: Only tried walkability. If it failed, the pair was rejected.
- After: Tries walkability first. If that fails, probes multiple candidates for a narrow water gap. Only rejects if BOTH checks fail.
- This fixes the **Crimea bug**: Crimea↔Krasnodar shares raster cells, walkability fails due to the Kerch Strait, but the water gap is only 1.2 studs → accepted as a strait.

---

### Step 5: Update Phase 2 (`calculateExtendedAdjacencies`) to use evidence-first classification

**File:** `src/shared/TileAdjacencyManager.luau`

**Function:** `calculateExtendedAdjacencies` (starts at line 1171)

**What to change:** Remove the distance-based branching (the `if rasterEdgeDistance <= EXTENDED_ADJACENCY_THRESHOLD` / `else` split) and replace it with a single `_classifyCandidatePair` call.

Find this block (lines 1249-1281):

```lua
			local shouldConnect = false

			-- Gate 2: Distance-based decision
			if rasterEdgeDistance <= EXTENDED_ADJACENCY_THRESHOLD then
				-- Close pairs (≤3 studs): require walkability proof (land adjacency)
				local bestCrossing = _getBestWalkableBorderCrossing(tileA, tileB, DEFAULT_CANDIDATE_K, "raster")
				if bestCrossing then
					shouldConnect = true
					if not AdjacencyProof[tileA] then AdjacencyProof[tileA] = {} end
					if not AdjacencyProof[tileB] then AdjacencyProof[tileB] = {} end
					AdjacencyProof[tileA][tileB] = { mode = "raster", pointA = bestCrossing.pointA, pointB = bestCrossing.pointB, distance = bestCrossing.distance }
					AdjacencyProof[tileB][tileA] = { mode = "raster", pointA = bestCrossing.pointB, pointB = bestCrossing.pointA, distance = bestCrossing.distance }
				else
					rejectedCount = rejectedCount + 1
					rejectedReasons.unwalkable = rejectedReasons.unwalkable + 1
				end
			else
				-- Wider pairs (3-8 studs): accept as narrow strait (no walkability needed)
				-- Water crossings with no intervening tile
				shouldConnect = true
				narrowStraitAcceptedCount = narrowStraitAcceptedCount + 1

				-- Use raster edge points for proof (marked as strait since it's a water crossing)
				if not AdjacencyProof[tileA] then AdjacencyProof[tileA] = {} end
				if not AdjacencyProof[tileB] then AdjacencyProof[tileB] = {} end
				AdjacencyProof[tileA][tileB] = { mode = "strait", pointA = rasterPtA, pointB = rasterPtB, distance = rasterEdgeDistance }
				AdjacencyProof[tileB][tileA] = { mode = "strait", pointA = rasterPtB, pointB = rasterPtA, distance = rasterEdgeDistance }

				if DEBUG_EXTENDED_ADJACENCY or DEBUG_REJECTED_ADJACENCY then
					print(string.format("[TileAdjacencyManager] Narrow-strait adjacency: %s <-> %s (raster: %.1f)",
						tileA.Name, tileB.Name, rasterEdgeDistance))
				end
			end
```

Replace with:

```lua
			local shouldConnect = false

			-- Gate 2: Evidence-first classification (replaces distance-based branching).
			-- Try walkability first (land), then probe for narrow strait if walkability fails.
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

**What this changes:**
- Before: Distance ≤ 3 → require walkability. Distance 3-8 → accept blindly.
- After: ALL pairs get evidence-first classification: try walkability, then probe for narrow strait.
- Logging now shows the actual `waterGapStuds` measurement, NOT `crossing.distance` (these are different values).
- This fixes the **Denmark bug**: Cross-sea pairs fail walkability with a wide water gap (5.6+ studs) → exceeds MAX_STRAIT_WATER_GAP → rejected.

---

### Step 6: Update `tryRepairAdjacencyPair` to use evidence-first classification

**File:** `src/shared/TileAdjacencyManager.luau`

**Function:** `tryRepairAdjacencyPair` (starts at line 2204)

**What to change:** Replace the Phase 2 distance-based branching with `_classifyCandidatePair`.

Find this block (the Phase 2 section, approximately lines 2236-2251):

```lua
	-- Phase 2 parity: extended (intervening check + distance-based decision)
	if not crossing and rasterEdgeDistance > 0 and rasterEdgeDistance <= NARROW_STRAIT_THRESHOLD then
		local hasIntervening = hasInterveningTileBetween(tileA, tileB, lookup)
		if not hasIntervening then
			if rasterEdgeDistance <= EXTENDED_ADJACENCY_THRESHOLD then
				local bestCrossing = _getBestWalkableBorderCrossing(tileA, tileB, DEFAULT_CANDIDATE_K, "raster")
				if bestCrossing then
					crossing = bestCrossing
					mode = "raster"
				end
			else
				-- Narrow strait: accept without walkability (water crossing)
				crossing = { pointA = rasterPtA, pointB = rasterPtB, distance = rasterEdgeDistance }
				mode = "strait"
			end
		end
	end
```

Replace with:

```lua
	-- Phase 2 parity: extended (intervening check + evidence-first classification)
	if not crossing and rasterEdgeDistance > 0 and rasterEdgeDistance <= NARROW_STRAIT_THRESHOLD then
		local hasIntervening = hasInterveningTileBetween(tileA, tileB, lookup)
		if not hasIntervening then
			local classification, classifyCrossing = _classifyCandidatePair(tileA, tileB, DEFAULT_CANDIDATE_K, "raster")
			if classification and classifyCrossing then
				crossing = classifyCrossing
				mode = (classification == "strait") and "strait" or "raster"
			end
		end
	end
```

**What this changes:**
- Before: Distance-based branching in repair (same bug as Phase 2).
- After: Uses the same evidence-first classification as the main pipeline, keeping repair parity.

---

### Step 7: Update `diagnoseAdjacency` to show evidence-first classification results

**File:** `src/shared/TileAdjacencyManager.luau`

**Function:** `diagnoseAdjacency` (starts at line 1741)

**What to change:** Replace both Phase 1 and Phase 2 diagnostics with `_classifyCandidatePair` results.

**7A: Update Phase 1 diagnostic.** Find this block (approximately lines 1783-1793):

```lua
	if shareGridNeighbor and rasterEdgeDist <= MAX_RASTER_ADJACENCY_DISTANCE then
		warn("  Phase 1 (raster): eligible")
		local bestCrossing = _getBestWalkableBorderCrossing(tileA, tileB, DEFAULT_CANDIDATE_K, "raster")
		if bestCrossing then
			warn(string.format("  Phase 1 PASS: walkable crossing found (dist=%.2f)", bestCrossing.distance))
		else
			warn("  Phase 1 FAIL: no walkable crossing (will fall through to Phase 2)")
		end
```

Replace with:

```lua
	if shareGridNeighbor and rasterEdgeDist <= MAX_RASTER_ADJACENCY_DISTANCE then
		warn("  Phase 1 (raster): eligible")
		local classification, crossing = _classifyCandidatePair(tileA, tileB, DEFAULT_CANDIDATE_K, "raster")
		if classification == "land" and crossing then
			warn(string.format("  Phase 1 PASS: land crossing (segment=%.2f)", crossing.distance))
		elseif classification == "strait" and crossing then
			local gapText = crossing.waterGapStuds and string.format("%.2f", crossing.waterGapStuds) or "?"
			warn(string.format("  Phase 1 PASS: narrow strait detected (segment=%.2f, water gap=%s)", crossing.distance, gapText))
		else
			warn("  Phase 1 FAIL: no land crossing and no valid narrow strait (will fall through to Phase 2)")
		end
```

**7B: Update Phase 2 diagnostic.** Find this block (approximately lines 1798-1810):

```lua
		if hasIntervening then
			warn("  Phase 2 BLOCKED: intervening tile detected")
		elseif rasterEdgeDist <= EXTENDED_ADJACENCY_THRESHOLD then
			warn(string.format("  Phase 2 close pair (rasterEdgeDist=%.2f <= %d): checking walkability", rasterEdgeDist, EXTENDED_ADJACENCY_THRESHOLD))
			local bestCrossing = _getBestWalkableBorderCrossing(tileA, tileB, DEFAULT_CANDIDATE_K, "raster")
			if bestCrossing then
				warn(string.format("  Phase 2 PASS: walkable crossing found (dist=%.2f)", bestCrossing.distance))
			else
				warn("  Phase 2 FAIL: no walkable crossing for close pair")
			end
		else
			warn(string.format("  Phase 2 PASS: narrow strait (rasterEdgeDist=%.2f > %d, no intervening tile)",
				rasterEdgeDist, EXTENDED_ADJACENCY_THRESHOLD))
		end
```

Replace with:

```lua
		if hasIntervening then
			warn("  Phase 2 BLOCKED: intervening tile detected")
		else
			local classification, crossing = _classifyCandidatePair(tileA, tileB, DEFAULT_CANDIDATE_K, "raster")
			if classification == "land" and crossing then
				warn(string.format("  Phase 2 PASS: land crossing (segment=%.2f)", crossing.distance))
			elseif classification == "strait" and crossing then
				local gapText = crossing.waterGapStuds and string.format("%.2f", crossing.waterGapStuds) or "?"
				warn(string.format("  Phase 2 PASS: narrow strait (segment=%.2f, water gap=%s)", crossing.distance, gapText))
			else
				warn("  Phase 2 FAIL: no walkable land crossing and no valid narrow strait (gap too wide, cliff, or poor terrain)")
			end
		end
```

---

### Step 8: Add safety-net entries to `STRAIT_CONNECTIONS`

**File:** `src/shared/TileAdjacencyManager.luau`

**Location:** The `STRAIT_CONNECTIONS` table (lines 76-95).

**What to add:** Add the Kerch Strait crossing as a safety net. The automatic evidence-first detection should handle it, but an explicit entry prevents regressions if the geometry changes. This is confirmed duplicate-safe: `applyExplicitStraitConnections()` checks `if alreadyAdj then ... skip` before inserting.

Find this comment (around line 91-94):

```lua
 	-- ================================================================
 	-- Add further crossings here as you expand the map:
	-- { "TileNameA", "TileNameB" },
	-- ================================================================
```

Replace with:

```lua
	-- ================================================================
	-- CRIMEA / RUSSIA
	-- ================================================================

	-- Kerch Strait: Crimea → Krasnodar.
	-- The strait is narrow (~1.2 studs at the closest point) and should be auto-detected
	-- by the evidence-first pipeline, but this explicit entry serves as a safety net.
	-- Duplicate-safe: applyExplicitStraitConnections() checks alreadyAdj before inserting.
	{ "кримська область", "Краснода́рский край" },

	-- ================================================================
	-- Add further crossings here as you expand the map:
	-- { "TileNameA", "TileNameB" },
	-- ================================================================
```

**CRITICAL:** The tile names must match EXACTLY as they appear in the game. The names above use Cyrillic characters with specific accents. Copy them character-for-character from the game data. The exact names are:
- Crimea: `кримська область` (all lowercase Ukrainian)
- Krasnodar: `Краснода́рский край` (Russian with accent mark on the second а)

---

### Step 9: Update the file header comment

**File:** `src/shared/TileAdjacencyManager.luau`

**Location:** Lines 1-6 (the file header comment).

Find:

```lua
-- TileAdjacencyManager (ModuleScript in ServerScriptService) - v26 SIMPLIFIED DECISION PIPELINE
-- Two-phase adjacency: Phase 1 raster (walkability-verified), Phase 2 extended (intervening check + distance-based decision)
-- Phase 1: Raster-adjacent pairs (shared raster cells + edge distance + walkability proof)
-- Phase 2: Extended adjacency with two branches: close pairs (≤3 studs, walkability) and narrow straits (3-8 studs, water crossings)
-- Proof modes: "raster" for land crossings, "strait" for water crossings
-- All AABB-based adjacency decisions removed. Explicit strait connections table for wider water crossings.
```

Replace with:

```lua
-- TileAdjacencyManager (ModuleScript in ServerScriptService) - v27 EVIDENCE-FIRST PIPELINE
-- Two-phase adjacency: Phase 1 raster, Phase 2 extended. Both use evidence-first classification.
-- Distance creates candidacy; raycast evidence determines land vs strait vs reject.
--   1. Try walkability (land crossing)
--   2. If walkability fails with a narrow water gap, accept as strait
--   3. Otherwise reject
-- Proof modes: "raster" for land crossings, "strait" for water crossings, "aabb" (legacy)
-- Explicit STRAIT_CONNECTIONS remain available for exceptional or wider water crossings.
```

---

### Step 10: Update the Phase 2 function comment

**File:** `src/shared/TileAdjacencyManager.luau`

**Location:** The comment above `calculateExtendedAdjacencies` (line 1170).

Find:

```lua
-- Phase 2: Extended adjacency (two-branch approach: close pairs with walkability, narrow straits without)
```

Replace with:

```lua
-- Phase 2: Extended adjacency (candidate pairs are distance-gated, then classified by evidence:
-- try walkability first, then narrow-strait detection if walkability fails)
```

---

### Step 11: Update the `NARROW_STRAIT_THRESHOLD` comment block

**File:** `src/shared/TileAdjacencyManager.luau`

**Location:** The comment block above `NARROW_STRAIT_THRESHOLD` (lines 45-53).

Find:

```lua
-- NARROW STRAIT RULE: Tiles within this distance are treated as traversable even across water.
-- This supports narrow-strait crossings (e.g., Calabria→Sicily, Øresund, Schleswig-Holstein→Denmark).
-- If narrow-strait crossings break, check this value and Phase 2 extended adjacency logic.
-- Separate from EXTENDED_ADJACENCY_THRESHOLD so straits wider than the gap-bridging limit
-- can still be crossed (e.g., Denmark straits are ~4-6 studs wide).
```

Replace with:

```lua
-- NARROW STRAIT CANDIDACY:
-- Maximum edge-to-edge distance for considering a pair as an adjacency candidate.
-- This is a broad-phase candidacy threshold, not a semantic classifier.
-- Pairs within this distance are examined by the evidence-first pipeline:
--   walkability pass -> land connection
--   walkability fail with narrow water gap -> strait connection
--   otherwise -> reject
-- If narrow-water crossings need retuning, check MAX_STRAIT_WATER_GAP.
```

---

## Fixed Decisions: Follow These Exactly

These decisions are **not optional**. Do not improvise alternatives.

### Decision 1: `isPathWalkable` reports diagnostics, but does NOT classify

It may return water gap estimate, cliff flag, and failure reason. But it does NOT decide land vs strait. That decision belongs in `_classifyCandidatePair`.

### Decision 2: Do NOT change `_getBestWalkableBorderCrossing`

It still does only one job: finding a true walkable crossing. No strait logic goes into that function.

### Decision 3: Do NOT change `hasInterveningTileBetween`

It is still only a veto/pre-filter. If there is an intervening tile, block. If not, that does NOT prove the pair should connect.

### Decision 4: Do NOT remove `EXTENDED_ADJACENCY_THRESHOLD`

Keep the constant definition. It is no longer used for decision branching in Phase 2, but it remains for compatibility and historical continuity.

### Decision 5: The ONLY new function is `_classifyCandidatePair`

Do not create any other new functions. All other changes are modifications to existing functions.

### Decision 6: Strait classification must NOT depend only on `reason == "water_gap"`

Check `waterGapStuds > 0 AND waterGapStuds <= MAX_STRAIT_WATER_GAP AND NOT failedDueToCliff`. This catches narrow water crossings regardless of which specific check triggered the rejection.

### Decision 7: Strait fallback must examine multiple candidate edge segments

Do not probe only the single closest edge point. Use `_findCandidateEdgePoints` to get multiple candidates and pick the narrowest qualifying water gap.

### Decision 8: Do NOT log `crossing.distance` as "water gap"

These are different measurements:
- `crossing.distance` = geometric segment length between chosen edge points
- `crossing.waterGapStuds` = estimated width of the water-like miss run during walkability probing

### Decision 9: Use `.luau` files on disk for all edits

Edit files at `src/shared/TileAdjacencyManager.luau` using the filesystem (Read/Edit tools). Do NOT use MCP `multi_edit` or `script_read`/`script_write` tools for making changes.

---

## Completion Checklist

The task is finished ONLY if ALL of the following are true:

1. `MAX_STRAIT_WATER_GAP = 5` constant exists in `TileAdjacencyManager.luau`
2. `isPathWalkable` accepts `opts.maxDistance` and returns `(boolean, diagnostics)` on every code path
3. `isPathWalkable` diagnostics always include `waterGapStuds` and `failedDueToCliff`
4. `waterGapStuds` is computed ONCE after the raycast loop (before the consecutive-misses check) and included in all subsequent returns
5. `_classifyCandidatePair` function exists and is the ONLY new helper
6. `_classifyCandidatePair` prefers land crossing first via `_getBestWalkableBorderCrossing`
7. `_classifyCandidatePair` probes MULTIPLE candidate segments for strait fallback (using `_findCandidateEdgePoints`)
8. `_classifyCandidatePair` rejects cliff-like failures as straits (checks `failedDueToCliff`)
9. `_classifyCandidatePair` does NOT rely only on `reason == "water_gap"` — it checks `waterGapStuds > 0 AND <= MAX_STRAIT_WATER_GAP AND NOT failedDueToCliff`
10. `calculateAdjacenciesFromFootprints` (Phase 1) uses `_classifyCandidatePair` instead of direct `_getBestWalkableBorderCrossing`
11. Phase 1 can now store either `mode = "raster"` or `mode = "strait"`
12. `calculateExtendedAdjacencies` (Phase 2) uses `_classifyCandidatePair` instead of distance-based branching
13. The old `if rasterEdgeDistance <= EXTENDED_ADJACENCY_THRESHOLD` / `else` branching is completely removed from Phase 2
14. `tryRepairAdjacencyPair` Phase 2 uses `_classifyCandidatePair` instead of distance-based branching
15. `diagnoseAdjacency` shows classification results from `_classifyCandidatePair`
16. Diagnostic logs print actual `waterGapStuds` rather than mislabeling `crossing.distance` as the gap
17. `кримська область` ↔ `Краснода́рский край` is in `STRAIT_CONNECTIONS`
18. File header says `v27 EVIDENCE-FIRST PIPELINE`
19. Phase 2 comment no longer says "two-branch approach" or "distance-based decision"
20. `NARROW_STRAIT_THRESHOLD` comment no longer says "treated as traversable even across water"
21. No other files were modified

---

## How To Verify After Implementation

Run the game and check the console output for:

1. **Crimea fix**: Look for either:
   - `[TileAdjacencyManager] Explicit strait registered: кримська область <-> Краснода́рский край` (from STRAIT_CONNECTIONS)
   - OR a Phase 1 strait detection log showing the pair was accepted with `mode = "strait"`

2. **Denmark fix**: Look for:
   - The `narrow-strait=N` count in the raster adjacency log should be LOWER than before (fewer false strait acceptances)
   - No `Narrow-strait adjacency` log entries for cross-island pairs like `Region Midtjylland <-> Odsherred Kommune`
   - The existing STRAIT_CONNECTIONS entries (`Schleswig-Holstein <-> Lolland Kommune`, `Region Syddanmark <-> Region Sydøstdanmark`) should still appear as registered

3. **No regressions**: The total connection count should be similar to before (±10). If it drops dramatically, check whether legitimate adjacencies are being rejected.

4. **Repair parity**: A pair classified during repair should match the main build logic — same acceptance/rejection behavior, same proof mode.

---

## Final Instruction For Claude Haiku 4.5

Implement **only** the steps above, in order, one at a time.

Each step tells you EXACTLY what to find and what to replace it with. Do not improvise or add anything not listed.

If a change seems to require modifying a function not listed in the steps, STOP and re-read the plan. The plan is complete — all necessary changes are described.

After all steps are done, verify every item in the Completion Checklist is true.
