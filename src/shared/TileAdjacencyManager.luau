-- TileAdjacencyManager (ModuleScript in ServerScriptService) - v27 EVIDENCE-FIRST PIPELINE
-- Two-phase adjacency: Phase 1 raster, Phase 2 extended. Both use evidence-first classification.
-- Distance creates candidacy; raycast evidence determines land vs strait vs reject.
--   1. Try walkability (land crossing)
--   2. If walkability fails with a narrow water gap, accept as strait
--   3. Otherwise reject
-- Proof modes: "raster" for land crossings, "strait" for water crossings, "aabb" (legacy)
-- Explicit STRAIT_CONNECTIONS remain available for exceptional or wider water crossings.

local Workspace = game:GetService("Workspace")
local EUROPE_MAP = Workspace:WaitForChild("EuropeMap", 10)

local TileAdjacencyManager = {}

local TileKeyUtils = require(game:GetService("ServerScriptService"):WaitForChild("TileKeyUtils", 10))

-- Lazy-load dependencies to avoid circular requires
local TileManager = nil
local function getTileManager()
	if not TileManager then
		TileManager = require(game:GetService("ServerScriptService"):WaitForChild("TileManager", 10))
	end
	return TileManager
end

-- Configuration
local RASTER_CELL_SIZE = 2          -- Grid cell size in studs (smaller = more precise, slower init)
-- FIX v19: Diagonal raster neighbors are the root cause of false adjacencies.
-- With RASTER_CELL_SIZE=2, diagonal cell-center distance = sqrt(2)*2 = 2.828 studs —
-- exactly the crossing distance in every bad Italy/Switzerland log. Switching to
-- 4-cardinal-only eliminates these false edges. Extended adjacency (Phase 2, threshold=3)
-- recovers any legitimate pairs that were only diagonally touching in the raster grid.
local ADJACENCY_ALLOW_DIAGONAL = false
local DEBUG = false
local BATCH_YIELD_AFTER = 80       -- yield after this many tiles while rasterizing (set 0 to disable)

-- FIX v9.5: Maximum distance for rasterization adjacencies
-- Even if cells are grid neighbors, tiles must be within this edge distance to be adjacent
-- Derived from RASTER_CELL_SIZE: diagonal cell neighbors are sqrt(2)*cell apart (~2.8 at cell=2).
-- A 3x multiple (6 studs) covers all real neighbors; clamp(2x,4x) keeps it cell-proportional.
local MAX_RASTER_ADJACENCY_DISTANCE = math.clamp(3 * RASTER_CELL_SIZE, 2 * RASTER_CELL_SIZE, 4 * RASTER_CELL_SIZE)
-- = clamp(6, 4, 8) = 6 studs when RASTER_CELL_SIZE = 2

-- Extended adjacency configuration (fixes gaps and validates diagonals)
-- INCREASED from 1.5 to 4 studs to allow more gap-bridging adjacencies
local EXTENDED_ADJACENCY_THRESHOLD = 3  -- max edge-to-edge distance (studs) to consider adjacent (was 5; tightened to eliminate cross-sea false positives)
-- NARROW STRAIT CANDIDACY:
-- Maximum edge-to-edge distance for considering a pair as an adjacency candidate.
-- This is a broad-phase candidacy threshold, not a semantic classifier.
-- Pairs within this distance are examined by the evidence-first pipeline:
--   walkability pass -> land connection
--   walkability fail with narrow water gap -> strait connection
--   otherwise -> reject
-- If narrow-water crossings need retuning, check MAX_STRAIT_WATER_GAP.
local NARROW_STRAIT_THRESHOLD = 8  -- max edge-to-edge distance (studs) to allow narrow-strait crossing
-- NOTE: Raised from 6→8 to cover the ~6-stud physical gap between Schleswig-Holstein and Lolland.
-- Raster cell centers can add up to RASTER_CELL_SIZE (2 studs) of overhead to the measured
-- edge distance, so a 6-stud physical strait can appear as ~7-8 studs in raster-cell distance.
local narrowStraitAcceptedCount = 0  -- Tracks adjacencies accepted as narrow straits in Phase 2 extended

-- Maximum measured water-gap width (in studs) that qualifies as an automatic strait.
-- Measured as: maxConsecutiveMisses * stepSize during the walkability raycast probe.
-- Gaps wider than this are open sea and will be rejected (unless in STRAIT_CONNECTIONS).
-- Tuned from real map measurements:
--   Kerch Strait (Crimea<->Krasnodar): 1.2 studs (accepted)
--   Little Belt (Jutland<->Funen): 2.8 studs (accepted)
--   Great Belt (Funen<->Zealand): 4.0 studs (accepted)
--   Open sea (Jutland<->Zealand): 5.6 studs (rejected)
local MAX_STRAIT_WATER_GAP = 5

-- EXPLICIT STRAIT CONNECTIONS
-- The automatic detection phases (Phase 1 raster + Phase 2 extended) may fail for water crossings
-- where tiles have overlapping AABBs but their actual land surfaces are separated by water
-- (e.g. Fehmarn Belt, the Great Belt). When geometry creates ambiguity around water gaps,
-- automatic detection may miss valid straits entirely.
-- Result: some water crossings fail to register, and movement fails at runtime.
--
-- The fundamental fix is to declare known water crossings explicitly so they are always
-- registered regardless of geometry.  This table is the single source of truth for
-- all named straits, sounds, and ferry routes in the game.
--
-- Rules:
--   • Both tile names must exactly match the Part.Name in the EuropeMap model.
--   • Unknown names are skipped with a warning at startup (check the output window).
--   • Pairs already registered by the raster/extended passes are logged but not double-added.
--   • AdjacencyProof is populated via findClosestEdgePointsBBox so the NPC pathfinder
--     has correct waypoints for the water crossing.
--
-- HOW TO ADD NEW STRAITS:
--   Simply append { "TileA", "TileB" } to the list below and restart the server.
local STRAIT_CONNECTIONS = {
	-- ================================================================
	-- DENMARK / GERMANY
	-- ================================================================

	-- Fehmarn Belt: Germany (Schleswig-Holstein) → Lolland, Denmark.
	-- Their AABBs overlap in both X and Z, causing automatic detection to misinterpret
	-- the water gap as part of the tile footprint. Must be explicit.
 	{ "Schleswig-Holstein", "Lolland Kommune" },
 
 	-- Great Belt / Jutland → Funen/Fyn area strait.
 	-- Region Syddanmark (southern Jutland) and Region Sydøstdanmark share
 	-- only a ~0.1-stud Z-AABB overlap, so the automatic geometry pass can still miss the intended water crossing.
 	{ "Region Syddanmark", "Region Sydøstdanmark" },

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
}

-- local VALIDATE_EXTENDED_ONLY = true     -- FIX v9.2: Only validate EXTENDED adjacencies, trust rasterization
local DEBUG_EXTENDED_ADJACENCY = false  -- enable to see which pairs get extended adjacency
local DEBUG_REJECTED_ADJACENCY = true   -- enable to see which adjacencies are rejected

-- FIX v9.3: Stricter water detection thresholds
local GROUND_RATIO_THRESHOLD = 0.85     -- Require 85% ground coverage (up from 60%)
local MAX_CONSECUTIVE_MISSES = 1        -- If 2+ consecutive points miss ground, it's a water gap

-- Top-k walkable border crossing: number of candidate boundary pairs to try before giving up
local DEFAULT_CANDIDATE_K = 5

-- Data structures
local TileParts = {}       -- TileParts[countryName] = { BasePart, ... }
local AdjacentTiles = {}   -- AdjacentTiles[tile] = { neighborPart, ... }
local AdjacencyProof = {}  -- AdjacencyProof[tile][neighbor] = { mode: "raster"|"strait"|"aabb"(legacy), pointA: Vector3, pointB: Vector3, distance: number }
local PositionToTiles = {} -- PositionToTiles["x,z"] = { BasePart, ... } (bucket — many-to-many, never overwrites)
local TileIdToPart = {}    -- TileIdToPart[tileId] = BasePart (unique, stable identity via TileId attribute)
local AllTilesList = {}    -- flat array of all tile parts

-- Rasterization data
local TileFootprint = {}   -- TileFootprint[tile] = { ["cx,cz"] = true, ... }
local CellToTile = {}      -- CellToTile["cx,cz"] = tile (first tile found at this cell) - optional
local TileSafeCenter = {}  -- TileSafeCenter[tile] = Vector3 (rasterization centroid, safe from edges)
local CellToTilesMap = {}  -- FIX v12: Cell -> list of tiles, populated during adjacency calc, used by extended adjacency
local _overlapMidpointLogged: {[string]: boolean} = {}  -- dedupe table: log overlapping-tile pairs once per adjacency build
local AmbiguousPositionalBucketCount = 0
local REPAIR_COOLDOWN_SECONDS = 30
local RepairCooldownByPair = {}

-- Precomputed ray params (fallback)
local GLOBAL_RAY_PARAMS = RaycastParams.new()
GLOBAL_RAY_PARAMS.FilterDescendantsInstances = {EUROPE_MAP}
GLOBAL_RAY_PARAMS.FilterType = Enum.RaycastFilterType.Include
GLOBAL_RAY_PARAMS.IgnoreWater = true

---------------------------------------------------
-- Helpers
---------------------------------------------------

local function getTileKey(position)
	return TileKeyUtils.getTileKey(position)
end

-- Convert world XZ to raster cell coordinates (integer indices)
local function worldToCell(worldX, worldZ)
	return math.floor(worldX / RASTER_CELL_SIZE), math.floor(worldZ / RASTER_CELL_SIZE)
end

local function cellKey(cx, cz)
	return cx .. "," .. cz
end

local function parseCellKey(key)
	local cx, cz = key:match("^(-?%d+),(-?%d+)$")
	return tonumber(cx), tonumber(cz)
end

-- Returns the world-space XZ axis-aligned bounding box (AABB) of a tile.
-- Uses CFrame corner projection — consistent with rasterizeTile and findClosestEdgePointsBBox.
-- This is a world-axis AABB, NOT a true OBB: for rotated tiles, AABB overlap can exist
-- even when the oriented rectangles don't fully intersect. This matches the precision
-- level of all other geometric functions in this system.
local function getProjectedXZBounds(tile)
	local cf = tile.CFrame
	local half = tile.Size / 2
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for sx = -1, 1, 2 do
		for sy = -1, 1, 2 do
			for sz = -1, 1, 2 do
				local c = cf:PointToWorldSpace(Vector3.new(sx * half.X, sy * half.Y, sz * half.Z))
				minX = math.min(minX, c.X); maxX = math.max(maxX, c.X)
				minZ = math.min(minZ, c.Z); maxZ = math.max(maxZ, c.Z)
			end
		end
	end
	return minX, maxX, minZ, maxZ
end

-- Midpoint of the overlapping world-space XZ AABB region between two tiles.
-- Only call when calculateEdgeDistance(tileA, tileB) <= 0 (confirmed AABB overlap).
-- insideA/insideB mean "inside the respective tile's world-space XZ AABB" —
-- NOT guaranteed inside the true oriented footprint if tiles are rotated.
-- Returns: overlapMidX, overlapMidZ, insideA, insideB
local function computeXZOverlapMidpoint(tileA, tileB)
	local minAX, maxAX, minAZ, maxAZ = getProjectedXZBounds(tileA)
	local minBX, maxBX, minBZ, maxBZ = getProjectedXZBounds(tileB)

	local overlapMidX = (math.max(minAX, minBX) + math.min(maxAX, maxBX)) * 0.5
	local overlapMidZ = (math.max(minAZ, minBZ) + math.min(maxAZ, maxBZ)) * 0.5

	-- Sanity: midpoint should lie inside both AABBs (would fail only on degenerate geometry)
	local insideA = overlapMidX >= minAX and overlapMidX <= maxAX and overlapMidZ >= minAZ and overlapMidZ <= maxAZ
	local insideB = overlapMidX >= minBX and overlapMidX <= maxBX and overlapMidZ >= minBZ and overlapMidZ <= maxBZ

	return overlapMidX, overlapMidZ, insideA, insideB
end

-- Calculate minimum edge-to-edge distance between two tiles (XZ plane only)
-- Returns the closest distance between any edges of the two tile bounding boxes
local function calculateEdgeDistance(tileA, tileB)
	local minAX, maxAX, minAZ, maxAZ = getProjectedXZBounds(tileA)
	local minBX, maxBX, minBZ, maxBZ = getProjectedXZBounds(tileB)

	-- Calculate gap in X and Z directions
	local gapX = 0
	if maxAX < minBX then
		gapX = minBX - maxAX
	elseif maxBX < minAX then
		gapX = minAX - maxBX
	end

	local gapZ = 0
	if maxAZ < minBZ then
		gapZ = minBZ - maxAZ
	elseif maxBZ < minAZ then
		gapZ = minAZ - maxBZ
	end

	-- If boxes overlap in both dimensions, distance is 0
	if gapX <= 0 and gapZ <= 0 then
		return 0
	end

	-- If they only have gap in one dimension, that's the distance
	if gapX <= 0 then return gapZ end
	if gapZ <= 0 then return gapX end

	-- If gap in both, return diagonal distance
	return math.sqrt(gapX * gapX + gapZ * gapZ)
end

-- FIX v21: True edge-touch predicate (not just "AABB gap ~0").
-- Returns true only when two tiles share a real edge contact: one axis has gap <= eps
-- AND the other axis has meaningful overlap (>= minOverlap studs).  This rejects:
--   • corner-touch (gap ~0 in both axes but no shared edge length)
--   • deep AABB overlap without actual border contact
--   • separated tiles whose bounding boxes happen to nearly align
local function aabbEdgeTouchXZ(tileA, tileB, eps, minOverlap)
	eps = eps or 0.1  -- studs: threshold below which AABB gap is "effectively zero"
	minOverlap = minOverlap or 0.5  -- studs of shared edge required; tune per map scale

	local minAX, maxAX, minAZ, maxAZ = getProjectedXZBounds(tileA)
	local minBX, maxBX, minBZ, maxBZ = getProjectedXZBounds(tileB)

	local overlapX = math.min(maxAX, maxBX) - math.max(minAX, minBX)
	local overlapZ = math.min(maxAZ, maxBZ) - math.max(minAZ, minBZ)

	-- Signed gaps: positive = separated, <=0 = overlapping/touching
	local gapX = math.max(minBX - maxAX, minAX - maxBX)
	local gapZ = math.max(minBZ - maxAZ, minAZ - maxBZ)

	-- Touch in X means gap is ~0 in X and they share meaningful Z overlap
	local touchInX = math.abs(gapX) <= eps and overlapZ >= minOverlap
	-- Touch in Z means gap is ~0 in Z and they share meaningful X overlap
	local touchInZ = math.abs(gapZ) <= eps and overlapX >= minOverlap

	return (touchInX or touchInZ), overlapX, overlapZ, gapX, gapZ
end

-- Find the closest edge points between two tiles using bounding box sampling (LEGACY)
-- Used only as fallback when raster footprints aren't available
local function findClosestEdgePointsBBox(tileA, tileB)
	local cfA = tileA.CFrame
	local cfB = tileB.CFrame
	local halfA = tileA.Size / 2
	local halfB = tileB.Size / 2

	local bestDistSq = math.huge
	local bestPointA, bestPointB = nil, nil

	local edgeSamplesA = {}
	local edgeSamplesB = {}

	local numSamples = 16
	for i = 0, numSamples do
		local t = i / numSamples
		table.insert(edgeSamplesA, cfA:PointToWorldSpace(Vector3.new(-halfA.X + t * 2 * halfA.X, halfA.Y, -halfA.Z)))
		table.insert(edgeSamplesA, cfA:PointToWorldSpace(Vector3.new(-halfA.X + t * 2 * halfA.X, halfA.Y, halfA.Z)))
		table.insert(edgeSamplesA, cfA:PointToWorldSpace(Vector3.new(-halfA.X, halfA.Y, -halfA.Z + t * 2 * halfA.Z)))
		table.insert(edgeSamplesA, cfA:PointToWorldSpace(Vector3.new(halfA.X, halfA.Y, -halfA.Z + t * 2 * halfA.Z)))

		table.insert(edgeSamplesB, cfB:PointToWorldSpace(Vector3.new(-halfB.X + t * 2 * halfB.X, halfB.Y, -halfB.Z)))
		table.insert(edgeSamplesB, cfB:PointToWorldSpace(Vector3.new(-halfB.X + t * 2 * halfB.X, halfB.Y, halfB.Z)))
		table.insert(edgeSamplesB, cfB:PointToWorldSpace(Vector3.new(-halfB.X, halfB.Y, -halfB.Z + t * 2 * halfB.Z)))
		table.insert(edgeSamplesB, cfB:PointToWorldSpace(Vector3.new(halfB.X, halfB.Y, -halfB.Z + t * 2 * halfB.Z)))
	end

	for _, pA in ipairs(edgeSamplesA) do
		for _, pB in ipairs(edgeSamplesB) do
			local dx = pA.X - pB.X
			local dz = pA.Z - pB.Z
			local distSq = dx * dx + dz * dz
			if distSq < bestDistSq then
				bestDistSq = distSq
				bestPointA = pA
				bestPointB = pB
			end
		end
	end

	return bestPointA, bestPointB, math.sqrt(bestDistSq)
end

-- FIX v10: Find closest edge points using raster footprints (actual tile surface)
-- Bounding box edges can be far from the actual tile surface on rotated/irregular tiles.
-- This function finds the closest pair of raster cell centers between two tiles,
-- giving accurate edge-crossing points on real walkable surface.
local function findClosestEdgePoints(tileA, tileB)
	local footprintA = TileFootprint[tileA]
	local footprintB = TileFootprint[tileB]

	-- Fallback to bounding box if footprints not available
	if not footprintA or not footprintB then
		return findClosestEdgePointsBBox(tileA, tileB)
	end

	-- Collect world positions from footprint cells for each tile
	-- Only use boundary cells (cells that have at least one neighbor NOT in the footprint)
	-- Note: uses inline offsets to avoid dependency on NEIGHBOR_OFFSETS (declared later in file)
	local boundaryOffsets = {
		{1, 0}, {-1, 0}, {0, 1}, {0, -1},
		{1, 1}, {1, -1}, {-1, 1}, {-1, -1}
	}
	local function getBoundaryCells(footprint)
		local cells = {}
		for cKey, _ in pairs(footprint) do
			local cx, cz = parseCellKey(cKey)
			if cx and cz then
				-- Check if this is a boundary cell (at least one neighbor is not in footprint)
				local isBoundary = false
				for _, offset in ipairs(boundaryOffsets) do
					local nKey = cellKey(cx + offset[1], cz + offset[2])
					if not footprint[nKey] then
						isBoundary = true
						break
					end
				end
				if isBoundary then
					-- Inline cell-to-world conversion (cellCenterWorldPos is defined later in file)
					local half = RASTER_CELL_SIZE * 0.5
					local wx = (cx * RASTER_CELL_SIZE) + half
					local wz = (cz * RASTER_CELL_SIZE) + half
					table.insert(cells, {x = wx, z = wz, cx = cx, cz = cz})
				end
			end
		end
		-- If no boundary cells found (single-cell tile), use all cells
		if #cells == 0 then
			for cKey, _ in pairs(footprint) do
				local cx, cz = parseCellKey(cKey)
				if cx and cz then
					local half = RASTER_CELL_SIZE * 0.5
					local wx = (cx * RASTER_CELL_SIZE) + half
					local wz = (cz * RASTER_CELL_SIZE) + half
					table.insert(cells, {x = wx, z = wz, cx = cx, cz = cz})
				end
			end
		end
		table.sort(cells, function(a, b)
			return a.cx < b.cx or (a.cx == b.cx and a.cz < b.cz)
		end)
		return cells
	end

	local boundaryCellsA = getBoundaryCells(footprintA)
	local boundaryCellsB = getBoundaryCells(footprintB)

	if #boundaryCellsA == 0 or #boundaryCellsB == 0 then
		return findClosestEdgePointsBBox(tileA, tileB)
	end

	-- Find the closest pair of boundary cells
	local bestDistSq = math.huge
	local bestCellA, bestCellB = nil, nil

	for _, cellA in ipairs(boundaryCellsA) do
		for _, cellB in ipairs(boundaryCellsB) do
			local dx = cellA.x - cellB.x
			local dz = cellA.z - cellB.z
			local distSq = dx * dx + dz * dz
			if distSq < bestDistSq then
				bestDistSq = distSq
				bestCellA = cellA
				bestCellB = cellB
			end
		end
	end

	if not bestCellA or not bestCellB then
		return findClosestEdgePointsBBox(tileA, tileB)
	end

	-- FIX v25: Shift from cell centers to cell edges (toward the opposing tile).
	-- Cell centers are RASTER_CELL_SIZE/2 inward from the true edge, inflating all
	-- distances by up to 1 full cell size. For cardinal-neighbor cells (center dist = 2),
	-- shifting each point 1 stud toward the other collapses the distance to 0 (touching).
	local shiftDx = bestCellB.x - bestCellA.x
	local shiftDz = bestCellB.z - bestCellA.z
	local shiftDist = math.sqrt(shiftDx * shiftDx + shiftDz * shiftDz)
	if shiftDist > 0 then
		local shift = math.min(RASTER_CELL_SIZE * 0.5, shiftDist * 0.5)
		local snx, snz = shiftDx / shiftDist, shiftDz / shiftDist
		bestCellA.x = bestCellA.x + snx * shift
		bestCellA.z = bestCellA.z + snz * shift
		bestCellB.x = bestCellB.x - snx * shift
		bestCellB.z = bestCellB.z - snz * shift
	end
	-- Recompute distance after edge correction
	bestDistSq = (bestCellB.x - bestCellA.x)^2 + (bestCellB.z - bestCellA.z)^2

	-- FIX v15: Check if tiles are ACTUALLY far apart despite close boundary cells
	-- (overlapping boundary cells but distant tile centers = false adjacency)
	local rawCellDist = math.sqrt(bestDistSq)
	local tileDelta = tileB.Position - tileA.Position
	local actualTileDistance = math.sqrt(tileDelta.X * tileDelta.X + tileDelta.Z * tileDelta.Z)

	-- FIX v16: Only enter the v15 branch when tiles are NOT physically touching (aabbDist > 0).
	-- When aabbDist == 0, the tiles share a real border and the closest boundary cells are
	-- legitimately adjacent — the v15 branch would incorrectly route them to BBox fallback,
	-- landing samples inside a third tile and causing walkability to fail.
	local _aabbDistV15 = calculateEdgeDistance(tileA, tileB)
	if rawCellDist < 0.5 and actualTileDistance > 10 and _aabbDistV15 > 0 then
		-- Raster cells coincide but tiles are not physically touching (aabbDist > 0) —
		-- this is a coincidental cell overlap on distant tiles, not a genuine shared border.
		-- Fall back to BBox sampling to find a real crossing.
		if DEBUG_EXTENDED_ADJACENCY then
			warn(string.format("[TileAdjacencyManager] Boundary cell overlap detected for distant tiles %s <-> %s (tile distance: %.1f studs, cell distance: %.1f), using AABB fallback",
				tileA.Name, tileB.Name, actualTileDistance, rawCellDist))
		end
		return findClosestEdgePointsBBox(tileA, tileB)
	end

	-- Use tile Y positions for the edge points
	local pointA = Vector3.new(bestCellA.x, tileA.Position.Y + tileA.Size.Y / 2, bestCellA.z)
	local pointB = Vector3.new(bestCellB.x, tileB.Position.Y + tileB.Size.Y / 2, bestCellB.z)

	return pointA, pointB, rawCellDist
end

---------------------------------------------------
-- Top-k candidate edge points (max-heap)
---------------------------------------------------

-- Max-heap helpers (keyed on .distSq, index-1 based)
local function heapSiftDown(heap, size, i)
	while true do
		local largest = i
		local left = 2 * i
		local right = 2 * i + 1
		if left <= size and heap[left].distSq > heap[largest].distSq then
			largest = left
		end
		if right <= size and heap[right].distSq > heap[largest].distSq then
			largest = right
		end
		if largest == i then break end
		heap[i], heap[largest] = heap[largest], heap[i]
		i = largest
	end
end

local function heapSiftUp(heap, i)
	while i > 1 do
		local parent = math.floor(i / 2)
		if heap[i].distSq > heap[parent].distSq then
			heap[i], heap[parent] = heap[parent], heap[i]
			i = parent
		else
			break
		end
	end
end

local function heapInsert(heap, size, k, entry)
	if size < k then
		size = size + 1
		heap[size] = entry
		heapSiftUp(heap, size)
		return size
	elseif entry.distSq < heap[1].distSq then
		heap[1] = entry
		heapSiftDown(heap, size, 1)
	end
	return size
end

-- AABB variant: top-k closest edge point candidates from bounding box sampling
-- Defined first so _findCandidateEdgePoints can reference it as a fallback
local function _findCandidateEdgePointsBBox(tileA, tileB, k)
	k = k or DEFAULT_CANDIDATE_K
	local cfA = tileA.CFrame
	local cfB = tileB.CFrame
	local halfA = tileA.Size / 2
	local halfB = tileB.Size / 2

	-- Build edge samples (same logic as findClosestEdgePointsBBox)
	local edgeSamplesA = {}
	local edgeSamplesB = {}
	local numSamples = 16

	for i = 0, numSamples do
		local t = i / numSamples
		table.insert(edgeSamplesA, cfA:PointToWorldSpace(Vector3.new(-halfA.X + t * 2 * halfA.X, halfA.Y, -halfA.Z)))
		table.insert(edgeSamplesA, cfA:PointToWorldSpace(Vector3.new(-halfA.X + t * 2 * halfA.X, halfA.Y, halfA.Z)))
		table.insert(edgeSamplesA, cfA:PointToWorldSpace(Vector3.new(-halfA.X, halfA.Y, -halfA.Z + t * 2 * halfA.Z)))
		table.insert(edgeSamplesA, cfA:PointToWorldSpace(Vector3.new(halfA.X, halfA.Y, -halfA.Z + t * 2 * halfA.Z)))

		table.insert(edgeSamplesB, cfB:PointToWorldSpace(Vector3.new(-halfB.X + t * 2 * halfB.X, halfB.Y, -halfB.Z)))
		table.insert(edgeSamplesB, cfB:PointToWorldSpace(Vector3.new(-halfB.X + t * 2 * halfB.X, halfB.Y, halfB.Z)))
		table.insert(edgeSamplesB, cfB:PointToWorldSpace(Vector3.new(-halfB.X, halfB.Y, -halfB.Z + t * 2 * halfB.Z)))
		table.insert(edgeSamplesB, cfB:PointToWorldSpace(Vector3.new(halfB.X, halfB.Y, -halfB.Z + t * 2 * halfB.Z)))
	end

	-- Build top-k max-heap of closest pairs
	local heap = {}
	local heapSize = 0

	for _, pA in ipairs(edgeSamplesA) do
		for _, pB in ipairs(edgeSamplesB) do
			local dx = pA.X - pB.X
			local dz = pA.Z - pB.Z
			local distSq = dx * dx + dz * dz
			heapSize = heapInsert(heap, heapSize, k, {
				distSq = distSq,
				pointA = pA,
				pointB = pB,
			})
		end
	end

	if heapSize == 0 then return {} end

	-- Extract and sort ascending by distance
	local candidates = {}
	for i = 1, heapSize do
		local entry = heap[i]
		table.insert(candidates, {
			pointA = entry.pointA,
			pointB = entry.pointB,
			distance = math.sqrt(entry.distSq),
		})
	end

	table.sort(candidates, function(a, b)
		return a.distance < b.distance
	end)

	return candidates
end

-- Returns top-k closest boundary-pair candidates using raster footprints
-- Each candidate: {pointA: Vector3, pointB: Vector3, distance: number}
-- Sorted ascending by distance
local function _findCandidateEdgePoints(tileA, tileB, k)
	k = k or DEFAULT_CANDIDATE_K
	local footprintA = TileFootprint[tileA]
	local footprintB = TileFootprint[tileB]

	-- Fallback to AABB variant if footprints not available
	if not footprintA or not footprintB then
		return _findCandidateEdgePointsBBox(tileA, tileB, k)
	end

	-- Reuse boundary cell extraction logic from findClosestEdgePoints
	local boundaryOffsets = {
		{1, 0}, {-1, 0}, {0, 1}, {0, -1},
		{1, 1}, {1, -1}, {-1, 1}, {-1, -1}
	}
	local function getBoundaryCells(footprint)
		local cells = {}
		for cKey, _ in pairs(footprint) do
			local cx, cz = parseCellKey(cKey)
			if cx and cz then
				local isBoundary = false
				for _, offset in ipairs(boundaryOffsets) do
					local nKey = cellKey(cx + offset[1], cz + offset[2])
					if not footprint[nKey] then
						isBoundary = true
						break
					end
				end
				if isBoundary then
					local half = RASTER_CELL_SIZE * 0.5
					local wx = (cx * RASTER_CELL_SIZE) + half
					local wz = (cz * RASTER_CELL_SIZE) + half
					table.insert(cells, {x = wx, z = wz, cx = cx, cz = cz})
				end
			end
		end
		if #cells == 0 then
			for cKey, _ in pairs(footprint) do
				local cx, cz = parseCellKey(cKey)
				if cx and cz then
					local half = RASTER_CELL_SIZE * 0.5
					local wx = (cx * RASTER_CELL_SIZE) + half
					local wz = (cz * RASTER_CELL_SIZE) + half
					table.insert(cells, {x = wx, z = wz, cx = cx, cz = cz})
				end
			end
		end
		table.sort(cells, function(a, b)
			return a.cx < b.cx or (a.cx == b.cx and a.cz < b.cz)
		end)
		return cells
	end

	local boundaryCellsA = getBoundaryCells(footprintA)
	local boundaryCellsB = getBoundaryCells(footprintB)

	if #boundaryCellsA == 0 or #boundaryCellsB == 0 then
		return _findCandidateEdgePointsBBox(tileA, tileB, k)
	end

	-- Build top-k max-heap of closest pairs
	local heap = {}
	local heapSize = 0

	for _, cellA in ipairs(boundaryCellsA) do
		for _, cellB in ipairs(boundaryCellsB) do
			local dx = cellA.x - cellB.x
			local dz = cellA.z - cellB.z
			local distSq = dx * dx + dz * dz
			heapSize = heapInsert(heap, heapSize, k, {
				distSq = distSq,
				cellA = cellA,
				cellB = cellB,
			})
		end
	end

	if heapSize == 0 then
		return _findCandidateEdgePointsBBox(tileA, tileB, k)
	end

	-- FIX v15: Check for overlapping boundary cells on distant tiles
	local minDistSq = math.huge
	for i = 1, heapSize do
		if heap[i].distSq < minDistSq then
			minDistSq = heap[i].distSq
		end
	end
	local rawMinDist = math.sqrt(minDistSq)
	local tileDelta = tileB.Position - tileA.Position
	local actualTileDistance = math.sqrt(tileDelta.X * tileDelta.X + tileDelta.Z * tileDelta.Z)

	-- FIX v16: Only enter the v15 branch when tiles are NOT physically touching (aabbDist > 0).
	-- When aabbDist == 0, the tiles share a real border and the closest boundary cells are
	-- legitimately adjacent — skipping to BBox would pick corner samples inside a third tile.
	local _aabbDistV15 = calculateEdgeDistance(tileA, tileB)
	if rawMinDist < 0.5 and actualTileDistance > 10 and _aabbDistV15 > 0 then
		-- Raster cells coincide but tiles are not physically touching (aabbDist > 0) —
		-- this is a coincidental cell overlap on distant tiles, not a genuine shared border.
		-- Fall back to BBox sampling to find a real crossing.
		if DEBUG_EXTENDED_ADJACENCY then
			warn(string.format("[TileAdjacencyManager] Candidate boundary cell overlap for distant tiles %s <-> %s (tile dist: %.1f, cell dist: %.1f), using AABB fallback",
				tileA.Name, tileB.Name, actualTileDistance, rawMinDist))
		end
		return _findCandidateEdgePointsBBox(tileA, tileB, k)
	end

	-- Extract from heap, apply cell-edge correction, and sort ascending by distance
	local candidates = {}
	for i = 1, heapSize do
		local entry = heap[i]
		-- FIX v25: Shift from cell centers to cell edges (toward opposing tile)
		local cAx, cAz = entry.cellA.x, entry.cellA.z
		local cBx, cBz = entry.cellB.x, entry.cellB.z
		local cdx = cBx - cAx
		local cdz = cBz - cAz
		local cdist = math.sqrt(cdx * cdx + cdz * cdz)
		if cdist > 0 then
			local cshift = math.min(RASTER_CELL_SIZE * 0.5, cdist * 0.5)
			local cnx, cnz = cdx / cdist, cdz / cdist
			cAx = cAx + cnx * cshift
			cAz = cAz + cnz * cshift
			cBx = cBx - cnx * cshift
			cBz = cBz - cnz * cshift
		end
		local correctedDx = cBx - cAx
		local correctedDz = cBz - cAz
		local dist = math.sqrt(correctedDx * correctedDx + correctedDz * correctedDz)
		local ptA = Vector3.new(cAx, tileA.Position.Y + tileA.Size.Y / 2, cAz)
		local ptB = Vector3.new(cBx, tileB.Position.Y + tileB.Size.Y / 2, cBz)
		table.insert(candidates, { pointA = ptA, pointB = ptB, distance = dist })
	end

	table.sort(candidates, function(a, b)
		return a.distance < b.distance
	end)

	return candidates
end

-- Unified edge point helpers: returns (pointA, pointB, distance) atomically
-- Ensures distance and points are always computed by the same function
local function getRasterEdge(tileA, tileB)
	local pointA, pointB, dist = findClosestEdgePoints(tileA, tileB)
	return pointA, pointB, dist
end

local function getAABBEdge(tileA, tileB)
	local dist = calculateEdgeDistance(tileA, tileB)
	local pointA, pointB = findClosestEdgePointsBBox(tileA, tileB)
	return pointA, pointB, dist
end

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

-- Forward declarations (defined later but called from the adjacency pipeline)
local hasInterveningTileBetween

-- FIX v18.1: Added MAX_STEP_HEIGHT to strictly prevent cliffs from passing as walkable
local function isPathWalkable(tileA, tileB, opts)
	opts = opts or {}
	local mode = opts.mode or "raster"
	local closestA, closestB, edgeDist

	-- Determine edge points based on opts
	if opts.pointA and opts.pointB then
		closestA, closestB = opts.pointA, opts.pointB
		edgeDist = opts.distance or math.sqrt((opts.pointA.X - opts.pointB.X)^2 + (opts.pointA.Z - opts.pointB.Z)^2)
	elseif mode == "raster" then
		closestA, closestB, edgeDist = getRasterEdge(tileA, tileB)
	elseif mode == "aabb" then
		closestA, closestB, edgeDist = getAABBEdge(tileA, tileB)
	else
		error("Invalid mode: " .. tostring(mode))
	end


	local maxDistance = opts.maxDistance or MAX_RASTER_ADJACENCY_DISTANCE
	if edgeDist > maxDistance then
		if DEBUG_REJECTED_ADJACENCY then
			warn(string.format("[DEBUG_WALKABLE] Rejected %s<->%s: edgeDist %.2f > maxDist %d (mode=%s)",
				tileA.Name, tileB.Name, edgeDist, maxDistance, mode))
		end
		if DEBUG_REJECTED_ADJACENCY then
			print(string.format("[TileAdjacencyManager] Rejected: %s <-> %s (edge distance %.1f > %d, %s mode)",
				tileA.Name, tileB.Name, edgeDist, maxDistance, mode))
		end
		return false, { reason = "too_far", waterGapStuds = 0, failedDueToCliff = false }
	end

	local rayHeight = math.max(closestA.Y, closestB.Y) + 20
	local heightDiff = math.abs(closestA.Y - closestB.Y)
	local rayLength = math.max(100, heightDiff + 50)

	-- Raycast against entire EuropeMap for standard water/cliff detection
	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {EUROPE_MAP}
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.IgnoreWater = true

	local numChecks = math.max(5, math.ceil(edgeDist / 0.4))
	local groundCount = 0
	local totalChecks = numChecks + 1
	local consecutiveMisses = 0
	local maxConsecutiveMisses = 0
	local groundResults = {}

	-- Strict Step Height Check Constants
	local MAX_STEP_HEIGHT = 3.5 -- Allows walking up hills but blocks sheer cliffs
	-- FIX v21: Track whether the PREVIOUS sample was a hit.  Only compare Y heights
	-- between consecutive hits.  The old code compared across gaps (miss runs),
	-- which could falsely detect a "cliff" when samples crossed a small void and
	-- landed on ground at a different height on the other side.
	local lastHitY = nil
	local lastWasHit = false
	local failedDueToCliff = false

	for i = 0, numChecks do
		local fraction = i / numChecks
		local checkX = closestA.X + (closestB.X - closestA.X) * fraction
		local checkZ = closestA.Z + (closestB.Z - closestA.Z) * fraction
		local origin = Vector3.new(checkX, rayHeight, checkZ)

		local result = Workspace:Raycast(origin, Vector3.new(0, -rayLength, 0), rayParams)

		if result then
			-- Only check step height between CONSECUTIVE ground hits.
			-- Skipping over miss runs avoids false cliff detection.
			if lastWasHit then
				local stepHeight = math.abs(result.Position.Y - lastHitY)
				if stepHeight > MAX_STEP_HEIGHT then
					failedDueToCliff = true
					if DEBUG_REJECTED_ADJACENCY then
						warn(string.format("[TileAdjacencyManager] Path rejected: cliff detected (%.1f stud drop) between %s and %s", stepHeight, tileA.Name, tileB.Name))
					end
					break -- Abort path check immediately
				end
			end

			lastHitY = result.Position.Y
			lastWasHit = true
			groundCount = groundCount + 1
			consecutiveMisses = 0
			table.insert(groundResults, true)
		else
			lastWasHit = false
			consecutiveMisses = consecutiveMisses + 1
			maxConsecutiveMisses = math.max(maxConsecutiveMisses, consecutiveMisses)
			table.insert(groundResults, false)
		end
	end

	-- Immediately fail if the step-height exceeded limits
	if failedDueToCliff then
		return false, { reason = "cliff", waterGapStuds = 0, failedDueToCliff = true }
	end

	local stepSize = edgeDist / math.max(1, numChecks)
	local waterGapStuds = maxConsecutiveMisses * stepSize

	if maxConsecutiveMisses > MAX_CONSECUTIVE_MISSES then
		if DEBUG_REJECTED_ADJACENCY then
			print(string.format("[TileAdjacencyManager] Rejected (WATER): %s <-> %s (%d consecutive misses, gap: %.1f studs, distance: %.1f)",
				tileA.Name, tileB.Name, maxConsecutiveMisses, waterGapStuds, edgeDist))
		end
		return false, { reason = "water_gap", waterGapStuds = waterGapStuds, failedDueToCliff = false }
	end

	local midIndex = math.floor(#groundResults / 2) + 1
	if #groundResults >= 3 then
		local midStart = math.max(1, midIndex - 1)
		local midEnd = math.min(#groundResults, midIndex + 1)
		local midGroundCount = 0
		for idx = midStart, midEnd do
			if groundResults[idx] then
				midGroundCount = midGroundCount + 1
			end
		end
		if midGroundCount < 2 then
			if DEBUG_REJECTED_ADJACENCY then
				print(string.format("[TileAdjacencyManager] Rejected (MID-WATER): %s <-> %s (only %d/3 middle points have ground)",
					tileA.Name, tileB.Name, midGroundCount))
			end
			return false, { reason = "midpoint", waterGapStuds = waterGapStuds, failedDueToCliff = false }
		end
	end

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
end

-- Finds the best walkable border crossing among top-k candidate boundary pairs.
-- Surface-corrects each candidate and revalidates the corrected segment inside the loop.
-- Returns {pointA, pointB, distance} of first walkable candidate, or nil.
local function _getBestWalkableBorderCrossing(tileA, tileB, k, mode)
	k = k or DEFAULT_CANDIDATE_K
	mode = mode or "raster"

	local candidates
	if mode == "aabb" then
		candidates = _findCandidateEdgePointsBBox(tileA, tileB, k)
	else
		candidates = _findCandidateEdgePoints(tileA, tileB, k)
	end

	if not candidates or #candidates == 0 then
		return nil
	end


	for i, candidate in ipairs(candidates) do
		-- Step 1: Surface-correct the candidate points
		local ptA = candidate.pointA
		local ptB = candidate.pointB
		local correctedA = TileAdjacencyManager.findNearestSurfacePoint(tileA, ptA)
		local correctedB = TileAdjacencyManager.findNearestSurfacePoint(tileB, ptB)
		if correctedA then ptA = correctedA end
		if correctedB then ptB = correctedB end

		-- Step 2: Recompute distance after correction
		local dx = ptA.X - ptB.X
		local dz = ptA.Z - ptB.Z
		local correctedDist = math.sqrt(dx * dx + dz * dz)


		-- Step 3: Validate the CORRECTED segment
		local walkable = isPathWalkable(tileA, tileB, {
			mode = mode,
			pointA = ptA,
			pointB = ptB,
			distance = correctedDist
		})
		if walkable then
			return { pointA = ptA, pointB = ptB, distance = correctedDist }
		end
	end

	return nil
end

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

-- return center world position (x,z) of a cell
local function cellCenterWorldPos(cx, cz)
	local half = RASTER_CELL_SIZE * 0.5
	return (cx * RASTER_CELL_SIZE) + half, (cz * RASTER_CELL_SIZE) + half
end

-- small helper to register a raster cell for a tile
local function registerCell(footprint, tilePart, cx, cz)
	local key = cellKey(cx, cz)
	footprint[key] = true
	if not CellToTile[key] then
		CellToTile[key] = tilePart
	end
end

---------------------------------------------------
-- Rasterization (integer-cell loops, whitelist raycasts)
---------------------------------------------------

local function rasterizeTile(tilePart)
	local footprint = {}
	local cf = tilePart.CFrame
	local halfSize = tilePart.Size / 2

	-- Compute world-space XZ bounds by projecting all 8 corners of OBB
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge

	for sx = -1, 1, 2 do
		for sy = -1, 1, 2 do
			for sz = -1, 1, 2 do
				local corner = cf:PointToWorldSpace(Vector3.new(
					sx * halfSize.X, sy * halfSize.Y, sz * halfSize.Z
					))
				minX = math.min(minX, corner.X)
				maxX = math.max(maxX, corner.X)
				minZ = math.min(minZ, corner.Z)
				maxZ = math.max(maxZ, corner.Z)
			end
		end
	end

	-- small padding
	minX = minX - 0.5
	maxX = maxX + 0.5
	minZ = minZ - 0.5
	maxZ = maxZ + 0.5

	-- convert to integer cell ranges
	local minCx, minCz = worldToCell(minX, minZ)
	local maxCx, maxCz = worldToCell(maxX, maxZ)

	-- build a whitelist RaycastParams for this tile (fast and deterministic)
	local localRayParams = RaycastParams.new()
	localRayParams.FilterDescendantsInstances = { tilePart }
	localRayParams.FilterType = Enum.RaycastFilterType.Include
	localRayParams.IgnoreWater = true

	-- ray height and direction tuned per tile
	local rayHeight = tilePart.Position.Y + tilePart.Size.Y + 20
	local rayDistance = tilePart.Size.Y + 40
	local rayDir = Vector3.new(0, -rayDistance, 0)

	-- iterate integer cell coords
	for cx = minCx, maxCx do
		for cz = minCz, maxCz do
			local wx, wz = cellCenterWorldPos(cx, cz)
			local origin = Vector3.new(wx, rayHeight, wz)
			local result = Workspace:Raycast(origin, rayDir, localRayParams)

			if result and result.Instance then
				-- whitelist ensures hit belongs to this tile
				registerCell(footprint, tilePart, cx, cz)
			end
		end
	end

	-- fallback: if no cells were hit (tiny tile or odd mesh), try center ray then force register
	local hasAny = false
	for _ in pairs(footprint) do hasAny = true; break end

	if not hasAny then
		local centerPos = tilePart.Position
		local origin = Vector3.new(centerPos.X, rayHeight, centerPos.Z)
		local result = Workspace:Raycast(origin, rayDir, localRayParams)

		if result and result.Instance then
			local cx, cz = worldToCell(centerPos.X, centerPos.Z)
			registerCell(footprint, tilePart, cx, cz)
		else
			-- Last resort: force-register center cell so tile has presence
			local cx, cz = worldToCell(centerPos.X, centerPos.Z)
			registerCell(footprint, tilePart, cx, cz)
			if DEBUG then
				warn("[TileAdjacencyManager] Force-registered center cell for: " .. tilePart:GetFullName())
			end
		end
	end

	TileFootprint[tilePart] = footprint
	return footprint
end

---------------------------------------------------
-- Adjacency from footprints
---------------------------------------------------

local NEIGHBOR_OFFSETS
if ADJACENCY_ALLOW_DIAGONAL then
	NEIGHBOR_OFFSETS = {
		{1, 0}, {-1, 0}, {0, 1}, {0, -1},
		{1, 1}, {1, -1}, {-1, 1}, {-1, -1}
	}
else
	NEIGHBOR_OFFSETS = {
		{1, 0}, {-1, 0}, {0, 1}, {0, -1}
	}
end


-- Intervening tile detection using raster footprints.
-- Samples 9 fractions along the edge-to-edge path and checks CellToTilesMap.
-- Returns true if 25% or more of samples find a third tile between tileA and tileB.
hasInterveningTileBetween = function(tileA, tileB, cellToTilesLookup)
	local ptA, ptB, edgeDist = findClosestEdgePoints(tileA, tileB)
	if not ptA or not ptB or edgeDist <= 0.5 then
		return false
	end

	local interveningCount = 0
	local totalSamples = 0

	for _, frac in ipairs({0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9}) do
		local sampleX = ptA.X + (ptB.X - ptA.X) * frac
		local sampleZ = ptA.Z + (ptB.Z - ptA.Z) * frac
		local sCx = math.floor(sampleX / RASTER_CELL_SIZE)
		local sCz = math.floor(sampleZ / RASTER_CELL_SIZE)
		local sKey = cellKey(sCx, sCz)
		local tilesAtSample = cellToTilesLookup[sKey]
		totalSamples = totalSamples + 1

		local foundIntervening = false
		if tilesAtSample then
			for _, sTile in ipairs(tilesAtSample) do
				if sTile ~= tileA and sTile ~= tileB then
					foundIntervening = true
					break
				end
			end
		end
		if foundIntervening then
			interveningCount = interveningCount + 1
		end
	end

	return interveningCount >= math.ceil(totalSamples * 0.25)
end


local function calculateAdjacenciesFromFootprints()
	narrowStraitAcceptedCount = 0  -- Reset counter for this adjacency build
	AdjacencyProof = {}  -- CRITICAL: Clear proof table on adjacency rebuild (server restart, map regen, hot-reload)
	_overlapMidpointLogged = _overlapMidpointLogged or {}
	table.clear(_overlapMidpointLogged)  -- Reset dedupe table so each rebuild logs overlap pairs once

	-- Build CellToTiles mapping (cell -> list of tiles that cover it)
	local CellToTilesLocal = {}

	for tile, footprint in pairs(TileFootprint) do
		for key, _ in pairs(footprint) do
			if not CellToTilesLocal[key] then
				CellToTilesLocal[key] = {}
			end
			table.insert(CellToTilesLocal[key], tile)
		end
	end

	-- FIX v12: Store for use by extended adjacency calculations
	CellToTilesMap = CellToTilesLocal

	-- Find adjacencies
	AdjacentTiles = {}
	local pairsSeen = {}
	local rejected = { distance = 0, unwalkable = 0, endpoint = 0 }

	for tileA, footprint in pairs(TileFootprint) do
		if not AdjacentTiles[tileA] then AdjacentTiles[tileA] = {} end
		if not pairsSeen[tileA] then pairsSeen[tileA] = {} end

		for key, _ in pairs(footprint) do
			local cx, cz = parseCellKey(key)
			if not cx then
				-- malformed key – skip
			else
				for _, offset in ipairs(NEIGHBOR_OFFSETS) do
					local ncx = cx + offset[1]
					local ncz = cz + offset[2]
					local nKey = cellKey(ncx, ncz)

					local tilesAt = CellToTilesLocal[nKey]
					if tilesAt then
						for _, tileB in ipairs(tilesAt) do
							if tileB ~= tileA and not pairsSeen[tileA][tileB] then
								pairsSeen[tileA][tileB] = true
								if not pairsSeen[tileB] then pairsSeen[tileB] = {} end
								pairsSeen[tileB][tileA] = true

								-- FIX v9.5/v18: Validate actual edge distance before marking as adjacent
								-- Use unified getRasterEdge helper for atomic (pointA, pointB, distance)
								local _ptA, _ptB, edgeDist = getRasterEdge(tileA, tileB)
								if edgeDist <= MAX_RASTER_ADJACENCY_DISTANCE then
									-- Phase 1: Raster-adjacent pairs. Use evidence-first classification:
									-- try walkability first (land), then probe for narrow strait if walkability fails.
									local classification, crossing = _classifyCandidatePair(tileA, tileB, DEFAULT_CANDIDATE_K, "raster")
									if classification and crossing then
										-- Evidence gate: validate proof endpoints hit the correct tiles.
										-- SKIP for edgeDist <= 0: tiles sharing raster cells are definitively adjacent.
										-- Raster cell-sharing is stronger evidence than raycast validation, and
										-- proof endpoints at cell boundaries often miss MeshPart geometry (causing
										-- false rejections like Bavaria <-> Baden Württemberg).
										local epValid = true
										local epReason = nil
										if edgeDist > 0 then
											epValid, epReason = validateProofEndpoints(tileA, tileB, crossing.pointA, crossing.pointB)
										end
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
								else
									rejected.distance = rejected.distance + 1
									if DEBUG then
										print(string.format("[TileAdjacencyManager] Rejected raster adjacency: %s <-> %s (edge distance %.1f > %d)",
											tileA.Name, tileB.Name, edgeDist, MAX_RASTER_ADJACENCY_DISTANCE))
									end
								end
							end
						end
					end
				end
			end
		end
	end

	-- Stats
	local totalConnections = 0
	for _, neighbors in pairs(AdjacentTiles) do
		totalConnections = totalConnections + #neighbors
	end
	totalConnections = totalConnections / 2

	local avgConnections = (totalConnections * 2) / math.max(1, #AllTilesList)
	print(string.format("[TileAdjacencyManager] Rasterization adjacency complete: %d connections, avg %.1f per tile (rejected: distance=%d, unwalkable=%d, endpoint=%d, narrow-strait=%d)",
		totalConnections, avgConnections, rejected.distance, rejected.unwalkable, rejected.endpoint, narrowStraitAcceptedCount))

	-- Top-5 tiles by neighbor count (outlier detection — tiles with unexpectedly many neighbors are suspicious)
	local tilesByDegree = {}
	for tile, neighbors in pairs(AdjacentTiles) do
		table.insert(tilesByDegree, { name = tile.Name, degree = #neighbors })
	end
	table.sort(tilesByDegree, function(a, b) return a.degree > b.degree end)
	local topN = math.min(5, #tilesByDegree)
	if topN > 0 then
		local parts = {}
		for i = 1, topN do
			table.insert(parts, tilesByDegree[i].name .. "(" .. tilesByDegree[i].degree .. ")")
		end
		print("[TileAdjacencyManager] Top-" .. topN .. " tiles by neighbor count: " .. table.concat(parts, ", "))
	end
end

-- Phase 2: Extended adjacency (candidate pairs are distance-gated, then classified by evidence:
-- try walkability first, then narrow-strait detection if walkability fails)
local function calculateExtendedAdjacencies()
	if EXTENDED_ADJACENCY_THRESHOLD <= 0 and NARROW_STRAIT_THRESHOLD <= 0 then
		print("[TileAdjacencyManager] Extended adjacency disabled (thresholds <= 0)")
		return
	end

	local extendedCount = 0
	local rejectedCount = 0
	local rejectedReasons = {
		intervening = 0,
		unwalkable = 0,
		endpoint = 0,
	}

	local function addAdjacency(a, b, existing)
		existing[a] = existing[a] or {}
		existing[b] = existing[b] or {}
		if existing[a][b] then return false end
		AdjacentTiles[a] = AdjacentTiles[a] or {}
		AdjacentTiles[b] = AdjacentTiles[b] or {}
		table.insert(AdjacentTiles[a], b)
		table.insert(AdjacentTiles[b], a)
		existing[a][b] = true
		existing[b][a] = true
		return true
	end

	-- Build quick lookup of existing adjacencies (from Phase 1 raster stage)
	local existingAdjacent = {}
	for tileA, neighbors in pairs(AdjacentTiles) do
		existingAdjacent[tileA] = existingAdjacent[tileA] or {}
		for _, tileB in ipairs(neighbors) do
			existingAdjacent[tileA][tileB] = true
			existingAdjacent[tileB] = existingAdjacent[tileB] or {}
			existingAdjacent[tileB][tileA] = true
		end
	end

	-- Single unified pass: check all non-raster-adjacent pairs within NARROW_STRAIT_THRESHOLD
	for i = 1, #AllTilesList do
		local tileA = AllTilesList[i]
		local halfDiagA = 0.5 * math.sqrt(tileA.Size.X * tileA.Size.X + tileA.Size.Z * tileA.Size.Z)

		for j = i + 1, #AllTilesList do
			local tileB = AllTilesList[j]

			-- Skip if already adjacent from Phase 1
			if existingAdjacent[tileA] and existingAdjacent[tileA][tileB] then
				continue
			end

			-- Quick center-to-center prefilter
			local diff = tileA.Position - tileB.Position
			local centerDistXZ = math.sqrt(diff.X * diff.X + diff.Z * diff.Z)
			local halfDiagB = 0.5 * math.sqrt(tileB.Size.X * tileB.Size.X + tileB.Size.Z * tileB.Size.Z)
			if centerDistXZ > halfDiagA + halfDiagB + NARROW_STRAIT_THRESHOLD then
				continue
			end

			-- Get raster edge distance
			local rasterPtA, rasterPtB, rasterEdgeDistance = findClosestEdgePoints(tileA, tileB)

			-- Skip pairs beyond the maximum threshold
			if rasterEdgeDistance <= 0 or rasterEdgeDistance > NARROW_STRAIT_THRESHOLD then
				continue
			end

			-- Gate 1: Check for intervening tiles (single function, raster-based)
			local hasIntervening = hasInterveningTileBetween(tileA, tileB, CellToTilesMap)
			if hasIntervening then
				rejectedCount = rejectedCount + 1
				rejectedReasons.intervening = rejectedReasons.intervening + 1
				if DEBUG_REJECTED_ADJACENCY then
					print(string.format("[TileAdjacencyManager] Extended rejected (intervening): %s <-> %s (raster: %.1f)",
						tileA.Name, tileB.Name, rasterEdgeDistance))
				end
				continue
			end

			local shouldConnect = false

			-- Gate 2: Evidence-first classification (replaces distance-based branching).
			-- Try walkability first (land), then probe for narrow strait if walkability fails.
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

			if shouldConnect then
				if addAdjacency(tileA, tileB, existingAdjacent) then
					extendedCount = extendedCount + 1
					if DEBUG_EXTENDED_ADJACENCY then
						print(string.format("[TileAdjacencyManager] Extended adjacency: %s <-> %s (raster: %.1f)",
							tileA.Name, tileB.Name, rasterEdgeDistance))
					end
				end
			end
		end

		-- Yield occasionally to prevent timeout
		if i % 50 == 0 then
			task.wait(0)
		end
	end

	print(string.format("[TileAdjacencyManager] Extended adjacency: added %d connections, rejected %d (intervening=%d, unwalkable=%d, endpoint=%d, narrow-strait=%d)",
		extendedCount, rejectedCount,
		rejectedReasons.intervening, rejectedReasons.unwalkable, rejectedReasons.endpoint, narrowStraitAcceptedCount))
end

---------------------------------------------------
-- Tile containment helper
---------------------------------------------------

-- Returns true if the given world position (XZ plane) falls within the tile's oriented bounding box.
-- Used to disambiguate multiple tiles sharing the same positional bucket key.
local function isPositionOnTile(tilePart, position)
	local cf = tilePart.CFrame
	local half = tilePart.Size / 2
	local localPos = cf:PointToObjectSpace(position)
	return math.abs(localPos.X) <= half.X and math.abs(localPos.Z) <= half.Z
end

---------------------------------------------------
-- Safe centroid calculation (prevents NPCs near edges)
---------------------------------------------------

-- Verify a position has tile surface beneath it using a whitelist raycast on the specific tile
local function hasTileSurfaceBelow(tile, worldX, worldZ)
	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = { tile }
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.IgnoreWater = true

	local rayHeight = tile.Position.Y + tile.Size.Y + 20
	local rayDir = Vector3.new(0, -(tile.Size.Y + 40), 0)
	local origin = Vector3.new(worldX, rayHeight, worldZ)

	local result = Workspace:Raycast(origin, rayDir, rayParams)
	return result ~= nil
end

-- Check if a cell is an "interior" cell (has neighbors on all 4 cardinal sides within the same footprint)
local function isInteriorCell(footprint, cx, cz)
	-- Check all 4 cardinal directions
	local cardinalOffsets = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
	for _, offset in ipairs(cardinalOffsets) do
		local neighborKey = cellKey(cx + offset[1], cz + offset[2])
		if not footprint[neighborKey] then
			return false -- Missing a neighbor, this is an edge cell
		end
	end
	return true
end

local function calculateSafeCenters()
	TileSafeCenter = {}
	local fallbackCount = 0
	local interiorUsedCount = 0
	local problemTiles = {}

	for tile, footprint in pairs(TileFootprint) do
		-- Collect all cells and separate into interior vs edge cells
		local allCells = {}
		local interiorCells = {}
		local sumAllX, sumAllZ = 0, 0
		local sumInteriorX, sumInteriorZ = 0, 0
		local allCount = 0
		local interiorCount = 0

		for key, _ in pairs(footprint) do
			local cx, cz = parseCellKey(key)
			if cx then
				local wx, wz = cellCenterWorldPos(cx, cz)
				local cellData = {wx = wx, wz = wz, cx = cx, cz = cz}
				table.insert(allCells, cellData)
				sumAllX = sumAllX + wx
				sumAllZ = sumAllZ + wz
				allCount = allCount + 1

				-- Check if this is an interior cell
				if isInteriorCell(footprint, cx, cz) then
					table.insert(interiorCells, cellData)
					sumInteriorX = sumInteriorX + wx
					sumInteriorZ = sumInteriorZ + wz
					interiorCount = interiorCount + 1
				end
			end
		end

		local safeY = tile.Position.Y + tile.Size.Y / 2 + 3

		-- Prefer interior cells for safe center calculation
		local _useCells, useSum, useCount
		if interiorCount > 0 then
			_useCells = interiorCells
			useSum = {x = sumInteriorX, z = sumInteriorZ}
			useCount = interiorCount
			interiorUsedCount = interiorUsedCount + 1
		else
			-- No interior cells (thin tile or single-cell tile), use all cells
			_useCells = allCells
			useSum = {x = sumAllX, z = sumAllZ}
			useCount = allCount
		end

		if useCount > 0 then
			local centroidX = useSum.x / useCount
			local centroidZ = useSum.z / useCount

			-- Verify the centroid has actual tile surface below it
			if hasTileSurfaceBelow(tile, centroidX, centroidZ) then
				TileSafeCenter[tile] = Vector3.new(centroidX, safeY, centroidZ)
			else
				-- Centroid is off-surface (concave/irregular tile)
				-- Find the cell closest to the centroid that IS on the tile surface
				-- Prefer interior cells first
				local bestDist = math.huge
				local bestX, bestZ = centroidX, centroidZ
				local foundValid = false

				-- First pass: try interior cells only
				for _, cell in ipairs(interiorCells) do
					if hasTileSurfaceBelow(tile, cell.wx, cell.wz) then
						local dx = cell.wx - centroidX
						local dz = cell.wz - centroidZ
						local dist = dx * dx + dz * dz
						if dist < bestDist then
							bestDist = dist
							bestX = cell.wx
							bestZ = cell.wz
							foundValid = true
						end
					end
				end

				-- Second pass: if no interior cell worked, try all cells
				if not foundValid then
					for _, cell in ipairs(allCells) do
						if hasTileSurfaceBelow(tile, cell.wx, cell.wz) then
							local dx = cell.wx - centroidX
							local dz = cell.wz - centroidZ
							local dist = dx * dx + dz * dz
							if dist < bestDist then
								bestDist = dist
								bestX = cell.wx
								bestZ = cell.wz
								foundValid = true
							end
						end
					end
				end

				if foundValid then
					TileSafeCenter[tile] = Vector3.new(bestX, safeY, bestZ)
				else
					-- Last resort: use geometric center
					TileSafeCenter[tile] = tile.Position + Vector3.new(0, tile.Size.Y / 2 + 3, 0)
					table.insert(problemTiles, {name = tile.Name, reason = "no_valid_cell_found"})
				end
				fallbackCount = fallbackCount + 1
			end
		else
			-- No raster cells: use geometric center
			TileSafeCenter[tile] = tile.Position + Vector3.new(0, tile.Size.Y / 2 + 3, 0)
		end
	end

	print(string.format("[TileAdjacencyManager] Safe centers calculated for %d tiles (%d used interior cells, %d needed surface fallback)",
		#AllTilesList, interiorUsedCount, fallbackCount))

	if #problemTiles > 0 then
		print("[TileAdjacencyManager] WARNING: " .. #problemTiles .. " tiles may have problematic safe centers:")
		for _, problem in ipairs(problemTiles) do
			print("  - " .. problem.name .. " (" .. problem.reason .. ")")
		end
	end
end

---------------------------------------------------
-- Initialization (scan & rasterize with batching)
---------------------------------------------------

local function scanAllTiles()
	TileParts = {}
	PositionToTiles = {}
	TileIdToPart = {}
	AllTilesList = {}

	for _, countryModel in ipairs(EUROPE_MAP:GetChildren()) do
		if countryModel:IsA("Model") then
			TileParts[countryModel.Name] = {}

			for _, part in ipairs(countryModel:GetDescendants()) do
				if part:IsA("BasePart") then
					table.insert(TileParts[countryModel.Name], part)
					table.insert(AllTilesList, part)

					-- Fix A: Assign a unique, stable TileId to each tile part.
					-- Prefer Studio-authored TileId attribute; fall back to GetFullName() which is
					-- deterministic for the session and independent of scan order / list length.
					local existingId = part:GetAttribute("TileId")
					if existingId then
						if TileIdToPart[existingId] then
							error("[TileAdjacencyManager] DUPLICATE TileId attribute: '" .. existingId ..
								"' on both " .. TileIdToPart[existingId]:GetFullName() ..
								" and " .. part:GetFullName())
						end
						TileIdToPart[existingId] = part
					else
						local tileId = part:GetFullName()
						if TileIdToPart[tileId] then
							error("[TileAdjacencyManager] DUPLICATE auto-generated TileId (GetFullName collision): '" ..
								tileId .. "' — rename one of the conflicting parts")
						end
						part:SetAttribute("TileId", tileId)
						TileIdToPart[tileId] = part
					end

					-- Fix B: Spatial bucket index — many-to-many, never overwrites.
					-- This is an approximate positional lookup only; use TileId for identity.
					local lookupPos = part.Position + Vector3.new(0, part.Size.Y / 2 + 3, 0)
					local key = getTileKey(lookupPos)
					if not PositionToTiles[key] then
						PositionToTiles[key] = {}
					end
					table.insert(PositionToTiles[key], part)
				end
			end
		end
	end

	-- Diagnostic: count ambiguous positional buckets (quantifies legacy-key risk)
	local totalBuckets = 0
	local ambiguousBuckets = 0
	for _, candidates in pairs(PositionToTiles) do
		totalBuckets = totalBuckets + 1
		if #candidates > 1 then
			ambiguousBuckets = ambiguousBuckets + 1
		end
	end
	AmbiguousPositionalBucketCount = ambiguousBuckets
	print(string.format("[TileAdjacencyManager] Scanned %d tiles across %d countries — all TileIds unique. Positional buckets: %d total, %d ambiguous (>1 tile per key)",
		#AllTilesList, #EUROPE_MAP:GetChildren(), totalBuckets, ambiguousBuckets))
end

local function rasterizeAllTiles()
	TileFootprint = {}
	CellToTile = {}

	local totalCells = 0
	local tilesProcessed = 0

	for idx, tile in ipairs(AllTilesList) do
		local fp = rasterizeTile(tile)
		local cellCount = 0
		for _ in pairs(fp) do cellCount = cellCount + 1 end
		totalCells = totalCells + cellCount
		tilesProcessed = tilesProcessed + 1

		if cellCount == 0 then
			warn("[TileAdjacencyManager] Tile has 0 raster cells after fallback: " .. tile:GetFullName()
				.. " (Size: " .. tostring(tile.Size) .. ")")
		end

		if idx % 200 == 0 or DEBUG then
			print(string.format("[TileAdjacencyManager] Rasterized %d/%d tiles (%d cells so far)...",
				idx, #AllTilesList, totalCells))
		end

		if BATCH_YIELD_AFTER > 0 and tilesProcessed >= BATCH_YIELD_AFTER then
			tilesProcessed = 0
			task.wait(0) -- yield a frame so server remains responsive
		end
	end

	print(string.format("[TileAdjacencyManager] Rasterization complete: %d total cells (avg %.1f per tile)",
		totalCells, totalCells / math.max(1, #AllTilesList)))
end

---------------------------------------------------
-- Visualization helpers (dev-only)
---------------------------------------------------

-- Parent folder for all footprint visuals
local VIS_ROOT_NAME = "FootprintVisuals"

local function ensureVisRoot()
	local root = workspace:FindFirstChild(VIS_ROOT_NAME)
	if not root then
		root = Instance.new("Folder")
		root.Name = VIS_ROOT_NAME
		root.Parent = workspace
	end
	return root
end

function TileAdjacencyManager.visualizeFootprint(tilePart, color3)
	if not tilePart then return end
	if not TileFootprint[tilePart] then
		warn("No footprint for", tilePart:GetFullName())
		return
	end

	local root = ensureVisRoot()
	-- per-tile group
	local groupName = "FP_" .. tostring(tilePart:GetDebugId() or tostring(tilePart):gsub("[^%w]", "_"))
	local prev = root:FindFirstChild(groupName)
	if prev then prev:Destroy() end

	local group = Instance.new("Folder")
	group.Name = groupName
	group.Parent = root

	for key, _ in pairs(TileFootprint[tilePart]) do
		local cx, cz = parseCellKey(key)
		if cx then
			local wx, wz = cellCenterWorldPos(cx, cz)
			local box = Instance.new("Part")
			box.Size = Vector3.new(RASTER_CELL_SIZE * 0.95, 0.2, RASTER_CELL_SIZE * 0.95)
			box.Anchored = true
			box.CanCollide = false
			box.Transparency = 0.35
			box.Position = Vector3.new(wx, tilePart.Position.Y + 0.1, wz)
			box.Color = color3 or Color3.fromRGB(255, 0, 0)
			box.Name = "cell_" .. key
			box.Parent = group
		end
	end

	return group
end

function TileAdjacencyManager.clearFootprintVisuals()
	local root = workspace:FindFirstChild(VIS_ROOT_NAME)
	if root then root:Destroy() end
end

---------------------------------------------------
-- Public API
---------------------------------------------------

function TileAdjacencyManager.getTileAtPosition(position)
	local key = getTileKey(position)
	local candidates = PositionToTiles[key]
	if not candidates then return nil end
	if #candidates == 1 then return candidates[1] end
	-- Disambiguate multiple tiles sharing this positional key using OBB containment
	for _, part in ipairs(candidates) do
		if isPositionOnTile(part, position) then
			return part
		end
	end
	return candidates[1]  -- fallback to first if no OBB match
end

-- Returns a tile by its TileId attribute (primary, unique path) or legacy positional hash (fallback).
-- Safe-failure policy: ambiguous positional keys return nil instead of silently guessing wrong tile.
function TileAdjacencyManager.getTileFromKey(tileKey)
	-- Primary: tileKey is a stable TileId (set via TileId attribute)
	local byId = TileIdToPart[tileKey]
	if byId then return byId end

	-- Legacy fallback: tileKey is a positional hash ("x,z")
	-- Only return if the bucket is unambiguous (exactly 1 candidate).
	local candidates = PositionToTiles[tileKey]
	if candidates then
		if #candidates == 1 then
			return candidates[1]
		elseif #candidates > 1 then
			if DEBUG then
				warn(string.format("[TileAdjacencyManager] getTileFromKey('%s') is ambiguous (%d candidates) — returning nil. Use getTileFromId() or getTileAtPosition().",
					tileKey, #candidates))
			end
			return nil  -- safe failure: caller must migrate to getTileFromId/getTileAtPosition
		end
	end
	return nil
end

-- New: look up a tile directly by its stable TileId attribute value.
function TileAdjacencyManager.getTileFromId(tileId)
	return TileIdToPart[tileId]
end

-- New: get the stable TileId attribute from a tile BasePart.
function TileAdjacencyManager.getTileId(tilePart)
	if not tilePart then return nil end
	return tilePart:GetAttribute("TileId")
end

-- New: test whether a world position (XZ) falls within a tile's oriented bounding box.
function TileAdjacencyManager.isPositionOnTile(tilePart, position)
	if not tilePart or not position then return false end
	return isPositionOnTile(tilePart, position)
end

function TileAdjacencyManager.getTileFromKeyWithFallback(tileKey)
	local tile = TileAdjacencyManager.getTileFromKey(tileKey)
	if tile then return tile end

	local x, z = TileKeyUtils.parseKey(tileKey)
	if not x or not z then return nil end

	local searchPos = Vector3.new(x, 100, z)
	return TileAdjacencyManager.getTileUnderPosition(searchPos)
end

function TileAdjacencyManager.getAdjacentTiles(tilePart)
	return AdjacentTiles[tilePart] or {}
end

function TileAdjacencyManager.areTilesAdjacent(tilePartA, tilePartB)
	if not tilePartA or not tilePartB then return false end
	if tilePartA == tilePartB then return true end

	local neighbors = AdjacentTiles[tilePartA]
	return neighbors and table.find(neighbors, tilePartB) ~= nil
end

-- Checks if two tiles share at least one raster-neighbor cell (cardinal directions only)
-- Returns true if any cell in tileA's footprint has a cardinal neighbor in tileB's footprint
local function sharesRasterNeighborCell(tileA, tileB)
	local footprintA = TileFootprint[tileA]
	local footprintB = TileFootprint[tileB]

	if not footprintA or not footprintB then
		return false
	end

	for key, _ in pairs(footprintA) do
		local cx, cz = parseCellKey(key)
		if cx then
			for _, offset in ipairs(NEIGHBOR_OFFSETS) do
				local neighborKey = cellKey(cx + offset[1], cz + offset[2])
				if footprintB[neighborKey] then
					return true
				end
			end
		end
	end

	return false
end

-- Runtime diagnostic for adjacency failures — mirrors the new two-phase pipeline
function TileAdjacencyManager.diagnoseAdjacency(tileA, tileB)
	if not tileA or not tileB then
		warn("[ADJACENCY DIAG] One or both tiles are nil")
		return
	end

	warn("=== ADJACENCY DIAGNOSTIC: " .. tileA.Name .. " <-> " .. tileB.Name .. " ===")

	-- Check footprints
	local footprintA = TileFootprint[tileA]
	local footprintB = TileFootprint[tileB]
	local cellCountA, cellCountB = 0, 0
	if footprintA then for _ in pairs(footprintA) do cellCountA = cellCountA + 1 end end
	if footprintB then for _ in pairs(footprintB) do cellCountB = cellCountB + 1 end end
	warn(string.format("  Raster footprint: %s has %d cells, %s has %d cells", tileA.Name, cellCountA, tileB.Name, cellCountB))

	if cellCountA == 0 or cellCountB == 0 then
		warn("  PROBLEM: One or both tiles have no raster footprint!")
		return
	end

	-- Distances
	local centerDistXZ = ((tileA.Position - tileB.Position) * Vector3.new(1, 0, 1)).Magnitude
	local _, _, rasterEdgeDist = findClosestEdgePoints(tileA, tileB)
	warn(string.format("  Center-to-center (XZ): %.2f studs", centerDistXZ))
	warn(string.format("  Raster edge distance: %.2f studs", rasterEdgeDist))

	-- Check if raster-adjacent (shared cardinal cells)
	local shareGridNeighbor = sharesRasterNeighborCell(tileA, tileB)
	warn(string.format("  Share grid neighbor cells: %s", tostring(shareGridNeighbor)))

	-- Phase 1: Raster adjacency check
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
	else
		warn(string.format("  Phase 1: not eligible (sharedCells=%s, edgeDist=%.2f, max=%d)",
			tostring(shareGridNeighbor), rasterEdgeDist, MAX_RASTER_ADJACENCY_DISTANCE))
	end

	-- Phase 2: Extended adjacency check
	if rasterEdgeDist > 0 and rasterEdgeDist <= NARROW_STRAIT_THRESHOLD then
		warn(string.format("  Phase 2 (extended): eligible (rasterEdgeDist=%.2f <= %d)", rasterEdgeDist, NARROW_STRAIT_THRESHOLD))

		local hasIntervening = hasInterveningTileBetween(tileA, tileB, CellToTilesMap)
		warn(string.format("  Phase 2 intervening tile check: %s", tostring(hasIntervening)))

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
	else
		warn(string.format("  Phase 2: not eligible (rasterEdgeDist=%.2f, range: 0-%d)", rasterEdgeDist, NARROW_STRAIT_THRESHOLD))
	end

	warn("=== END DIAGNOSTIC ===")
end

function TileAdjacencyManager.getTileCountry(tilePart)
	if not tilePart then return nil end
	local current = tilePart.Parent
	while current and current ~= EUROPE_MAP and current ~= Workspace do
		if current.Parent == EUROPE_MAP then
			return current.Name
		end
		current = current.Parent
	end
	return nil
end

-- Returns the current controlling country of a tile.
-- Checks OwnerCountry attribute first (set on BOTH capture and annexation),
-- then falls back to geographic Model parent (original owner).
-- INVARIANT: All non-geographic control (occupation, annexation) sets OwnerCountry.
-- Use this for "who currently controls this tile?" decisions.
-- Use getTileCountry() for "where does this tile geographically belong?" decisions.
function TileAdjacencyManager.getEffectiveOwner(tilePart)
	if not tilePart then return nil end
	local ownerAttr = tilePart:GetAttribute("OwnerCountry")
	if ownerAttr and ownerAttr ~= "" then
		return ownerAttr
	end
	return TileAdjacencyManager.getTileCountry(tilePart)
end

function TileAdjacencyManager.getAdjacentEnemyTiles(tilePart)
	local adjacents = AdjacentTiles[tilePart] or {}
	local myCountry = TileAdjacencyManager.getTileCountry(tilePart)
	local enemyTiles = {}

	for _, adjTile in ipairs(adjacents) do
		local adjCountry = TileAdjacencyManager.getTileCountry(adjTile)
		if adjCountry and adjCountry ~= myCountry then
			table.insert(enemyTiles, adjTile)
		end
	end
	return enemyTiles
end

function TileAdjacencyManager.canNPCsInteract(npcA, npcB)
	-- Prefer CurrentTileId (stable, unique TileId of the tile the NPC is on) over legacy TileKey (lossy positional hash)
	local idA = npcA:GetAttribute("CurrentTileId") or npcA:GetAttribute("TileKey")
	local idB = npcB:GetAttribute("CurrentTileId") or npcB:GetAttribute("TileKey")

	if not idA or not idB then return false end
	if idA == idB then return true end

	-- getTileFromKey tries TileIdToPart first (stable), then PositionToTiles bucket (safe-failure on ambiguous)
	local tileA = TileAdjacencyManager.getTileFromKey(idA) or TileAdjacencyManager.getTileFromKeyWithFallback(idA)
	local tileB = TileAdjacencyManager.getTileFromKey(idB) or TileAdjacencyManager.getTileFromKeyWithFallback(idB)

	return TileAdjacencyManager.areTilesAdjacent(tileA, tileB)
end

function TileAdjacencyManager.arePositionsAdjacent(positionA, positionB)
	local tileA = TileAdjacencyManager.getTileAtPosition(positionA)
	local tileB = TileAdjacencyManager.getTileAtPosition(positionB)
	return TileAdjacencyManager.areTilesAdjacent(tileA, tileB)
end

function TileAdjacencyManager.areTileKeysAdjacent(tileKeyA, tileKeyB)
	if not tileKeyA or not tileKeyB then return false end
	if tileKeyA == tileKeyB then return true end

	local tileA = TileAdjacencyManager.getTileFromKey(tileKeyA)
	local tileB = TileAdjacencyManager.getTileFromKey(tileKeyB)

	if not tileA then tileA = TileAdjacencyManager.getTileFromKeyWithFallback(tileKeyA) end
	if not tileB then tileB = TileAdjacencyManager.getTileFromKeyWithFallback(tileKeyB) end

	if not tileA or not tileB then return false end
	return TileAdjacencyManager.areTilesAdjacent(tileA, tileB)
end

function TileAdjacencyManager.getTileUnderPosition(position)
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = {EUROPE_MAP}
	params.FilterType = Enum.RaycastFilterType.Include
	params.IgnoreWater = true

	local rayOrigin = Vector3.new(position.X, 200, position.Z)
	local rayDirection = Vector3.new(0, -400, 0)

	local result = Workspace:Raycast(rayOrigin, rayDirection, params)
	if result and result.Instance and result.Instance:IsA("BasePart") then
		return result.Instance
	end

	return nil
end

-- Debug info
function TileAdjacencyManager.debugAdjacency(tileA, tileB)
	if not tileA or not tileB then
		print("[DEBUG] One or both tiles are nil")
		return
	end

	local inTable = AdjacentTiles[tileA] and table.find(AdjacentTiles[tileA], tileB)
	local fpA = TileFootprint[tileA]
	local fpB = TileFootprint[tileB]
	local cellCountA = 0
	local cellCountB = 0
	if fpA then for _ in pairs(fpA) do cellCountA = cellCountA + 1 end end
	if fpB then for _ in pairs(fpB) do cellCountB = cellCountB + 1 end end

	local centerDist = ((tileA.Position - tileB.Position) * Vector3.new(1, 0, 1)).Magnitude

	print("=== ADJACENCY DEBUG (v9.3 Water Fix) ===")
	print("Tile A:", tileA.Name, "Country:", TileAdjacencyManager.getTileCountry(tileA), "Cells:", cellCountA)
	print("Tile B:", tileB.Name, "Country:", TileAdjacencyManager.getTileCountry(tileB), "Cells:", cellCountB)
	print("Center distance:", string.format("%.2f", centerDist))
	print("In precomputed table:", inTable ~= nil)
	print("Neighbor count A:", #(AdjacentTiles[tileA] or {}))
	print("Neighbor count B:", #(AdjacentTiles[tileB] or {}))
	print("==========================================")
end

function TileAdjacencyManager.getSafeCenter(tilePart)
	if not tilePart then return nil end
	return TileSafeCenter[tilePart]
end

function TileAdjacencyManager.findClosestEdgePoints(tileA, tileB)
	if not tileA or not tileB then return nil, nil, math.huge end
	return findClosestEdgePoints(tileA, tileB)
end

function TileAdjacencyManager.findCandidateEdgePoints(tileA, tileB, k)
	if not tileA or not tileB then return {} end
	return _findCandidateEdgePoints(tileA, tileB, k)
end

function TileAdjacencyManager.getBestWalkableBorderCrossing(tileA, tileB, k, mode)
	if not tileA or not tileB then return nil end
	return _getBestWalkableBorderCrossing(tileA, tileB, k, mode)
end

-- FIX v10: Find the nearest point on a tile's actual surface to a target XZ position.
-- Used to validate/correct edge crossing waypoints that may land off-tile on irregular shapes.
-- Returns a corrected Vector3 on the tile surface, or nil if no surface found.
function TileAdjacencyManager.findNearestSurfacePoint(tile, targetPoint)
	if not tile or not targetPoint then return nil end

	-- Create raycast params that only hit this specific tile
	local tileRayParams = RaycastParams.new()
	tileRayParams.FilterDescendantsInstances = { tile }
	tileRayParams.FilterType = Enum.RaycastFilterType.Include
	tileRayParams.IgnoreWater = true

	-- First check if the target point itself has surface on this tile
	local rayOrigin = Vector3.new(targetPoint.X, tile.Position.Y + 50, targetPoint.Z)
	local result = Workspace:Raycast(rayOrigin, Vector3.new(0, -100, 0), tileRayParams)
	if result and result.Instance == tile then
		return Vector3.new(targetPoint.X, result.Position.Y, targetPoint.Z)
	end

	-- Target point has no surface on this tile - search nearby raster cells for closest valid point
	local footprint = TileFootprint[tile]
	if not footprint then return nil end

	local bestPoint, bestDistSq = nil, math.huge
	for cKey, _ in pairs(footprint) do
		local cx, cz = cKey:match("^(-?%d+),(-?%d+)$")
		cx, cz = tonumber(cx), tonumber(cz)
		if cx and cz then
			-- Convert cell coords back to world position (center of cell)
			local worldX = (cx + 0.5) * RASTER_CELL_SIZE
			local worldZ = (cz + 0.5) * RASTER_CELL_SIZE
			local dx = worldX - targetPoint.X
			local dz = worldZ - targetPoint.Z
			local distSq = dx * dx + dz * dz
			if distSq < bestDistSq then
				-- Verify this cell has actual surface on the tile
				local cellRayOrigin = Vector3.new(worldX, tile.Position.Y + 50, worldZ)
				local cellResult = Workspace:Raycast(cellRayOrigin, Vector3.new(0, -100, 0), tileRayParams)
				if cellResult and cellResult.Instance == tile then
					bestDistSq = distSq
					bestPoint = Vector3.new(worldX, cellResult.Position.Y, worldZ)
				end
			end
		end
	end
	return bestPoint
end

-- BFS through raster cells to find a walkable path from startPos to endPos within a tile.
-- Returns an array of Vector3 world positions (cell centers) forming the path, excluding
-- the start and end cells. Returns empty table if no path found or positions are off-tile.
function TileAdjacencyManager.findCellPath(tilePart, startPos, endPos)
	if not tilePart then return {} end
	local footprint = TileFootprint[tilePart]
	if not footprint then return {} end

	-- Convert world positions to cell coordinates
	local startCX, startCZ = worldToCell(startPos.X, startPos.Z)
	local endCX, endCZ = worldToCell(endPos.X, endPos.Z)

	local startKey = cellKey(startCX, startCZ)
	local endKey = cellKey(endCX, endCZ)

	-- If start cell isn't on the tile, find the nearest cell that is
	if not footprint[startKey] then
		local bestDist = math.huge
		local bestCX, bestCZ = startCX, startCZ
		for key, _ in pairs(footprint) do
			local cx, cz = parseCellKey(key)
			if cx then
				local dx = cx - startCX
				local dz = cz - startCZ
				local dist = dx * dx + dz * dz
				if dist < bestDist then
					bestDist = dist
					bestCX = cx
					bestCZ = cz
				end
			end
		end
		startCX, startCZ = bestCX, bestCZ
		startKey = cellKey(startCX, startCZ)
	end

	-- If end cell isn't on the tile, find the nearest cell that is
	if not footprint[endKey] then
		local bestDist = math.huge
		local bestCX, bestCZ = endCX, endCZ
		for key, _ in pairs(footprint) do
			local cx, cz = parseCellKey(key)
			if cx then
				local dx = cx - endCX
				local dz = cz - endCZ
				local dist = dx * dx + dz * dz
				if dist < bestDist then
					bestDist = dist
					bestCX = cx
					bestCZ = cz
				end
			end
		end
		endCX, endCZ = bestCX, bestCZ
		endKey = cellKey(endCX, endCZ)
	end

	-- Trivial case: same cell
	if startKey == endKey then return {} end

	-- A* through raster cells (using Manhattan distance heuristic)
	-- Node: { cx, cz, key, g, f, parentKey }
	local openSet = {}   -- key -> node
	local closedSet = {} -- key -> true
	local cameFrom = {}  -- key -> parentKey

	local startNode = {
		cx = startCX, cz = startCZ, key = startKey,
		g = 0,
		f = math.abs(endCX - startCX) + math.abs(endCZ - startCZ)
	}
	openSet[startKey] = startNode

	-- Neighbor offsets (8-connected to match tile adjacency)
	local cellNeighborOffsets = {
		{1, 0, 1.0}, {-1, 0, 1.0}, {0, 1, 1.0}, {0, -1, 1.0},
		{1, 1, 1.414}, {1, -1, 1.414}, {-1, 1, 1.414}, {-1, -1, 1.414}
	}

	local iterations = 0
	local maxIterations = 2000  -- safety limit

	while true do
		iterations = iterations + 1
		if iterations > maxIterations then break end

		-- Find node with lowest f in openSet
		local bestKey = nil
		local bestF = math.huge
		for key, node in pairs(openSet) do
			if node.f < bestF then
				bestF = node.f
				bestKey = key
			end
		end

		if not bestKey then break end  -- no path found

		local current = openSet[bestKey]
		openSet[bestKey] = nil
		closedSet[bestKey] = true

		-- Check if we've reached the destination
		if current.key == endKey then
			-- Reconstruct path
			local path = {}
			local traceKey = endKey
			while traceKey and traceKey ~= startKey do
				local tcx, tcz = parseCellKey(traceKey)
				if tcx and traceKey ~= endKey then  -- exclude start and end
					local wx, wz = cellCenterWorldPos(tcx, tcz)
					table.insert(path, 1, Vector3.new(wx, 0, wz))  -- Y will be set by caller
				end
				traceKey = cameFrom[traceKey]
			end
			return path
		end

		-- Expand neighbors
		for _, offset in ipairs(cellNeighborOffsets) do
			local ncx = current.cx + offset[1]
			local ncz = current.cz + offset[2]
			local nKey = cellKey(ncx, ncz)

			if footprint[nKey] and not closedSet[nKey] then
				local tentativeG = current.g + offset[3]
				local existing = openSet[nKey]

				if not existing or tentativeG < existing.g then
					local h = math.abs(endCX - ncx) + math.abs(endCZ - ncz)
					openSet[nKey] = {
						cx = ncx, cz = ncz, key = nKey,
						g = tentativeG,
						f = tentativeG + h
					}
					cameFrom[nKey] = current.key
				end
			end
		end
	end

	-- No path found through the tile's raster cells
	return {}
end

function TileAdjacencyManager.getStats()
	local total = 0
	for _, neighbors in pairs(AdjacentTiles) do
		total = total + #neighbors
	end
	return {
		totalTiles = #AllTilesList,
		totalConnections = total / 2,
		avgConnectionsPerTile = total / math.max(1, #AllTilesList)
	}
end

function TileAdjacencyManager.getAmbiguousPositionalBucketCount()
	return AmbiguousPositionalBucketCount
end

local function ensureAdjacencyAndProof(tileA, tileB, mode, crossing)
	if not tileA or not tileB or not crossing then
		return false
	end

	AdjacentTiles[tileA] = AdjacentTiles[tileA] or {}
	AdjacentTiles[tileB] = AdjacentTiles[tileB] or {}
	if not table.find(AdjacentTiles[tileA], tileB) then
		table.insert(AdjacentTiles[tileA], tileB)
	end
	if not table.find(AdjacentTiles[tileB], tileA) then
		table.insert(AdjacentTiles[tileB], tileA)
	end

	AdjacencyProof[tileA] = AdjacencyProof[tileA] or {}
	AdjacencyProof[tileB] = AdjacencyProof[tileB] or {}
	AdjacencyProof[tileA][tileB] = {
		mode = mode,
		pointA = crossing.pointA,
		pointB = crossing.pointB,
		distance = crossing.distance,
	}
	AdjacencyProof[tileB][tileA] = {
		mode = mode,
		pointA = crossing.pointB,
		pointB = crossing.pointA,
		distance = crossing.distance,
	}

	return true
end

local function getRepairPairKey(tileA, tileB)
	local idA = TileAdjacencyManager.getTileId(tileA) or tileA:GetDebugId()
	local idB = TileAdjacencyManager.getTileId(tileB) or tileB:GetDebugId()
	if tostring(idA) > tostring(idB) then
		idA, idB = idB, idA
	end
	return tostring(idA) .. "->" .. tostring(idB)
end

function TileAdjacencyManager.tryRepairAdjacencyPair(tileA, tileB)
	if not tileA or not tileB or tileA == tileB then
		return false
	end

	local pairKey = getRepairPairKey(tileA, tileB)
	local now = os.clock()
	local lastAttempt = RepairCooldownByPair[pairKey]
	if lastAttempt and (now - lastAttempt) < REPAIR_COOLDOWN_SECONDS then
		return false
	end
	RepairCooldownByPair[pairKey] = now

	local lookup = CellToTilesMap or {}

	local rasterPtA, rasterPtB, rasterEdgeDistance = findClosestEdgePoints(tileA, tileB)
	local crossing = nil
	local mode = nil

	-- Phase 1 parity: raster-adjacent with walkability
	if sharesRasterNeighborCell(tileA, tileB) and rasterEdgeDistance <= MAX_RASTER_ADJACENCY_DISTANCE then
		local bestCrossing = _getBestWalkableBorderCrossing(tileA, tileB, DEFAULT_CANDIDATE_K, "raster")
		if bestCrossing then
			-- Skip validation gate for cell-sharing tiles (rasterEdgeDistance <= 0):
			-- same rationale as Phase 1 init — cell-sharing is definitive adjacency evidence.
			local epValid = true
			if rasterEdgeDistance > 0 then
				epValid = validateProofEndpoints(tileA, tileB, bestCrossing.pointA, bestCrossing.pointB)
			end
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
end

---------------------------------------------------
-- Explicit strait connections (fundamental fix)
---------------------------------------------------

-- Registers every pair in STRAIT_CONNECTIONS as adjacent unconditionally.
-- Called after calculateExtendedAdjacencies() so it can fill in crossings
-- that the Phase 1 raster and Phase 2 extended passes cannot detect.
--
-- Each registered pair gets:
--   • An entry in AdjacentTiles (bidirectional)
--   • An AdjacencyProof with mode="strait" and the closest-edge waypoints
--     (computed by findClosestEdgePointsBBox, which is AABB-safe regardless
--     of whether raster footprints exist for the pair).
--
-- The proof mode is "strait" to indicate a water crossing that has been
-- explicitly declared and pre-approved by the adjacency system.
local function applyExplicitStraitConnections()
	if #STRAIT_CONNECTIONS == 0 then return end

	-- Build a name → BasePart lookup from the already-scanned tile list.
	local tileByName = {}
	for _, tilePart in ipairs(AllTilesList) do
		tileByName[tilePart.Name] = tilePart
	end

	local addedCount = 0

	for _, pair in ipairs(STRAIT_CONNECTIONS) do
		local nameA, nameB = pair[1], pair[2]
		local tileA = tileByName[nameA]
		local tileB = tileByName[nameB]

		if not tileA then
			warn(string.format("[TileAdjacencyManager] STRAIT_CONNECTIONS: tile '%s' not found in map — skipped (check Part.Name spelling)", nameA))
		elseif not tileB then
			warn(string.format("[TileAdjacencyManager] STRAIT_CONNECTIONS: tile '%s' not found in map — skipped (check Part.Name spelling)", nameB))
		else
			-- Check whether this pair is already adjacent from the raster/extended passes.
			local alreadyAdj = false
			if AdjacentTiles[tileA] then
				for _, nb in ipairs(AdjacentTiles[tileA]) do
					if nb == tileB then alreadyAdj = true; break end
				end
			end

			if alreadyAdj then
				-- Pair was found geometrically — no action needed, but log so it's visible.
				print(string.format("[TileAdjacencyManager] Explicit strait (already adjacent, skipping): %s <-> %s", nameA, nameB))
			else
				-- Force-register the adjacency (bidirectional).
				AdjacentTiles[tileA] = AdjacentTiles[tileA] or {}
				AdjacentTiles[tileB] = AdjacentTiles[tileB] or {}
				table.insert(AdjacentTiles[tileA], tileB)
				table.insert(AdjacentTiles[tileB], tileA)

				-- Compute closest bbox edge points for NPC waypoint accuracy.
				-- findClosestEdgePointsBBox is used (not the raster version) because for
				-- AABB-overlapping tiles the raster edge can return zero-distance points
				-- that land inside the tile surface rather than at the water's edge.
				local ptA, ptB, dist = findClosestEdgePointsBBox(tileA, tileB)

				-- Populate AdjacencyProof so NPCTargetingHandler's secondary validation
				-- (getAdjacencyProof check) does not block the movement.
				-- Mode "strait" indicates this is a water crossing intentionally accepted by the adjacency system.
				AdjacencyProof[tileA] = AdjacencyProof[tileA] or {}
				AdjacencyProof[tileB] = AdjacencyProof[tileB] or {}
				AdjacencyProof[tileA][tileB] = {
					mode = "strait",
					pointA = ptA,
					pointB = ptB,
					distance = dist,
				}
				AdjacencyProof[tileB][tileA] = {
					mode = "strait",
					pointA = ptB,
					pointB = ptA,
					distance = dist,
				}

				addedCount = addedCount + 1
				print(string.format("[TileAdjacencyManager] Explicit strait registered: %s <-> %s (bbox dist=%.2f studs)", nameA, nameB, dist))
			end
		end
	end

	print(string.format("[TileAdjacencyManager] Explicit strait connections: %d new pair(s) registered (%d total declared)",
		addedCount, #STRAIT_CONNECTIONS))
end

function TileAdjacencyManager.recalculate()
	rasterizeAllTiles()
	calculateAdjacenciesFromFootprints()
	calculateExtendedAdjacencies()
	applyExplicitStraitConnections()
	calculateSafeCenters()
end

-- FIX v18: Export isPathWalkable for use in NPCMovementSystem
-- Now uses opts table for unambiguous parameters
function TileAdjacencyManager.isPathWalkable(tileA, tileB, opts)
	return isPathWalkable(tileA, tileB, opts)
end

-- FIX v18: Export getAdjacencyProof for use in NPCMovementSystem
-- Returns adjacency proof for a tile pair, or nil if not adjacent
-- Returns: { mode: "raster"|"strait"|"aabb"(legacy), pointA: Vector3, pointB: Vector3, distance: number } or nil
function TileAdjacencyManager.getAdjacencyProof(tileA, tileB)
	if AdjacencyProof[tileA] and AdjacencyProof[tileA][tileB] then
		return AdjacencyProof[tileA][tileB]
	end
	return nil
end

---------------------------------------------------
-- Init
---------------------------------------------------

scanAllTiles()
rasterizeAllTiles()
calculateAdjacenciesFromFootprints()
calculateExtendedAdjacencies()
applyExplicitStraitConnections()
calculateSafeCenters()

return TileAdjacencyManager
