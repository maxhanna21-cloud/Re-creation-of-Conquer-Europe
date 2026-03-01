-- TileAdjacencyManager (ModuleScript in ServerScriptService) - v21 FALSE ADJACENCY REJECTION FIX
-- FIX v9.2: Less aggressive adjacency validation (trust rasterization)
-- FIX v9.3: Stricter water detection for extended adjacencies
--   - Increased ground ratio from 60% to 85%
--   - Added consecutive gap detection (2+ misses = water crossing)
--   - Explicit midpoint check (most likely water location)
-- FIX v12: AABB rescue for tiles with short shared borders (missed by rasterization)
-- FIX v12.1: AABB rescue now requires BOTH walkability AND no intervening tile
--   - Prevents false adjacencies between nearby land tiles separated by other tiles
--   - Uses bbox-based intervening tile check with dense sampling

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
-- 4-cardinal-only eliminates these false edges. Extended adjacency (Path A, threshold=3)
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
-- NARROW STRAIT RULE: Tiles within this distance are treated as traversable even across water.
-- This supports narrow-strait crossings (e.g., Calabria→Sicily, Øresund, Schleswig-Holstein→Denmark).
-- If narrow-strait crossings break, check this value and the isPathWalkable fast-path.
-- Separate from EXTENDED_ADJACENCY_THRESHOLD so straits wider than the gap-bridging limit
-- can still be crossed (e.g., Denmark straits are ~4-6 studs wide).
local NARROW_STRAIT_THRESHOLD = 8  -- max edge-to-edge distance (studs) to allow narrow-strait crossing
-- NOTE: Raised from 6→8 to cover the ~6-stud physical gap between Schleswig-Holstein and Lolland.
-- Raster cell centers can add up to RASTER_CELL_SIZE (2 studs) of overhead to the measured
-- edge distance, so a 6-stud physical strait can appear as ~7-8 studs in raster-cell distance.
local narrowStraitFastPathCount = 0  -- Tracks adjacencies accepted via narrow-strait fast-path

-- EXPLICIT STRAIT CONNECTIONS
-- The automatic detection paths (A/B/C) rely on raster-cell distance and AABB proximity.
-- When two tiles have overlapping AABBs but their actual land surfaces are separated by water
-- (e.g. Fehmarn Belt, the Great Belt), both distances come out near-zero:
--   • Path B fires (AABB rescue) but its hard ≤2.0-stud crossing gate blocks the water gap.
--   • Path C never fires because rasterEdgeDist ≈ 0 (overlap → condition "rasterEdgeDist > 0" is false).
-- Result: neither path registers the adjacency, and movement fails at runtime.
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
	-- Their AABBs overlap in both X and Z so geometric detection always
	-- reads AABB-distance = 0, triggering Path B whose ≤2.0-stud gate
	-- then rejects the real water gap.  Must be explicit.
	{ "Schleswig-Holstein", "Lolland Kommune" },

	-- Great Belt / Jutland → Funen/Fyn area strait.
	-- Region Syddanmark (southern Jutland) and Region Sydøstdanmark share
	-- only a ~0.1-stud Z-AABB overlap, so AABB-distance = 0 again and
	-- the same Path-B rejection applies.
	{ "Region Syddanmark", "Region Sydøstdanmark" },

	-- ================================================================
	-- Add further crossings here as you expand the map:
	-- { "TileNameA", "TileNameB" },
	-- ================================================================
}

-- local VALIDATE_EXTENDED_ONLY = true     -- FIX v9.2: Only validate EXTENDED adjacencies, trust rasterization
local DEBUG_EXTENDED_ADJACENCY = false  -- enable to see which pairs get extended adjacency
local DEBUG_REJECTED_ADJACENCY = true   -- FIX v9.3: Debug which adjacencies are rejected (enabled for testing)
local DEBUG_INTERVENING_COUNTS = false  -- FIX v13: Print near-threshold intervening counts (enable only when diagnosing specific pairs)

-- FIX v12: AABB-based adjacency rescue for tiles with short shared borders
-- Catches tiles that touch geometrically but were missed by rasterization.
-- Derived from RASTER_CELL_SIZE: rescue is only needed for tiles within ~1 cell seam of each other.
-- Clamp: min = 1 cell (RASTER_CELL_SIZE studs), max = 2 cells (2*RASTER_CELL_SIZE studs).
-- At cell=2: clamp(ceil(1.5*2), 2, 4) = clamp(3, 2, 4) = 3 studs.
-- This is safely below the smallest tile dimension in the map (~4 studs per Geometry.MD).
local AABB_ADJACENCY_RESCUE_THRESHOLD = math.clamp(math.ceil(1.5 * RASTER_CELL_SIZE), RASTER_CELL_SIZE, 2 * RASTER_CELL_SIZE)
-- = 3 studs when RASTER_CELL_SIZE = 2

-- FIX v21: Epsilon for "tiles physically touch" AABB checks.
-- calculateEdgeDistance returns 0 when AABBs overlap in both X and Z, but floating-point
-- noise can produce tiny positive values for genuinely touching tiles.  This epsilon
-- defines the threshold below which AABB gap is treated as "effectively zero."
local AABB_TOUCH_EPSILON = 0.1  -- studs

-- FIX v9.3: Stricter water detection thresholds
local GROUND_RATIO_THRESHOLD = 0.85     -- Require 85% ground coverage (up from 60%)
local MAX_CONSECUTIVE_MISSES = 1        -- If 2+ consecutive points miss ground, it's a water gap

-- Top-k walkable border crossing: number of candidate boundary pairs to try before giving up
local DEFAULT_CANDIDATE_K = 5

-- Data structures
local TileParts = {}       -- TileParts[countryName] = { BasePart, ... }
local AdjacentTiles = {}   -- AdjacentTiles[tile] = { neighborPart, ... }
local AdjacencyProof = {}  -- AdjacencyProof[tile][neighbor] = { mode: "raster"|"aabb", pointA: Vector3, pointB: Vector3, distance: number }
local PositionToTiles = {} -- PositionToTiles["x,z"] = { BasePart, ... } (bucket — many-to-many, never overwrites)
local TileIdToPart = {}    -- TileIdToPart[tileId] = BasePart (unique, stable identity via TileId attribute)
local AllTilesList = {}    -- flat array of all tile parts

-- Rasterization data
local TileFootprint = {}   -- TileFootprint[tile] = { ["cx,cz"] = true, ... }
local CellToTile = {}      -- CellToTile["cx,cz"] = tile (first tile found at this cell) - optional
local TileSafeCenter = {}  -- TileSafeCenter[tile] = Vector3 (rasterization centroid, safe from edges)
local CellToTilesMap = {}  -- FIX v12: Cell -> list of tiles, populated during adjacency calc, used by extended adjacency
local _overlapMidpointLogged: {[string]: boolean} = {}  -- dedupe table: log overlapping-tile pairs once per adjacency build

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
	eps = eps or AABB_TOUCH_EPSILON
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

	-- Extract from heap and sort ascending by distance
	local candidates = {}
	for i = 1, heapSize do
		local entry = heap[i]
		local dist = math.sqrt(entry.distSq)
		local ptA = Vector3.new(entry.cellA.x, tileA.Position.Y + tileA.Size.Y / 2, entry.cellA.z)
		local ptB = Vector3.new(entry.cellB.x, tileB.Position.Y + tileB.Size.Y / 2, entry.cellB.z)
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

-- Forward declarations (defined later but called from isPathWalkable)
local hasInterveningTileBetween
local hasInterveningTileByAABB  -- AABB-based fallback for tiles with raster gaps

-- FIX v18.1: Added MAX_STEP_HEIGHT to strictly prevent cliffs from passing as walkable
local function isPathWalkable(tileA, tileB, opts)
	opts = opts or {}
	local mode = opts.mode or "raster"
	local narrowStraitOverride = false  -- FIX v21: local flag, not stored on opts (avoids state leakage)
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

	-- TEMP DEBUG for specific problem pairs
	local DEBUG_WALKABLE_PAIR = tileA and tileB and (
		(tileA.Name:find("Kujawsko") or tileB.Name:find("Kujawsko")) or
		(tileA.Name:find("Wielkopolskie") or tileB.Name:find("Wielkopolskie"))
	)
	if DEBUG_WALKABLE_PAIR then
		warn(string.format("[DEBUG_WALKABLE] isPathWalkable %s<->%s mode=%s edgeDist=%.2f opts.ptA=%s",
			tileA.Name, tileB.Name, mode, edgeDist, opts.pointA and string.format("(%.1f,%.1f)", opts.pointA.X, opts.pointA.Z) or "nil"))
	end

	-- NARROW STRAIT RULE: only fast-path when CellToTilesMap is populated AND no intervening tile.
	-- If CellToTilesMap is empty/unavailable, skip fast-path entirely and fall through to full checks —
	-- taking the shortcut without intervening-tile detection would recreate the exact "skip tile" bug.
	-- Uses NARROW_STRAIT_THRESHOLD (wider than EXTENDED_ADJACENCY_THRESHOLD) to support wider
	-- water crossings like the Danish straits (~4-6 studs).
	if edgeDist <= NARROW_STRAIT_THRESHOLD then
		local _, _, rasterDist = getRasterEdge(tileA, tileB)
		if rasterDist <= NARROW_STRAIT_THRESHOLD then
			if CellToTilesMap and next(CellToTilesMap) ~= nil then
				local hasIntervening = hasInterveningTileBetween(tileA, tileB, CellToTilesMap)
				-- NOTE (v19): The AABB-based fallback was removed from here because it fired
				-- on the raster phase's walkability checks too (not just extended adjacency),
				-- causing over-rejection of legitimate Swiss adjacencies. The AABB guard now
				-- lives exclusively in Path A of calculateExtendedAdjacencies, where it uses
				-- tile centers (more robust) rather than boundary points.
				if DEBUG_WALKABLE_PAIR then
					warn(string.format("[DEBUG_WALKABLE] narrow-strait: rasterDist=%.2f hasIntervening=%s", rasterDist, tostring(hasIntervening)))
				end
				if not hasIntervening then
					narrowStraitFastPathCount = narrowStraitFastPathCount + 1
					if DEBUG_EXTENDED_ADJACENCY then
						print(string.format("[TileAdjacencyManager] Walkable (narrow-strait fast-path via raster: %.1f, %s mode): %s <-> %s",
							rasterDist, mode, tileA.Name, tileB.Name))
					end
					return true
				else
					-- FIX v21: When tiles physically touch (AABB distance == 0), the raster
					-- intervening check is unreliable (sampling path clips through neighboring
					-- tile cells due to grid quantization). Instead of immediately rejecting,
					-- fall through to the full ground-raycast walkability checks below.
					-- The raycasts will correctly detect actual terrain walkability.
					-- Only hard-reject when tiles DON'T touch (real water/gap scenario).
					local edgeTouchFP = aabbEdgeTouchXZ(tileA, tileB)
					if not edgeTouchFP then
						-- No real edge contact — intervening tile is likely genuine. Reject.
						if DEBUG_WALKABLE_PAIR then
							warn(string.format("[DEBUG_WALKABLE] narrow-strait REJECTED (intervening tile, no edge touch) %s<->%s", tileA.Name, tileB.Name))
						end
						return false
					else
						-- Tiles share real AABB edge contact — raster intervening check is
						-- suspect due to cell quantization.  Fall through to tile-filtered
						-- ground raycasts for a definitive answer.
						narrowStraitOverride = true
						if DEBUG_WALKABLE_PAIR then
							warn(string.format("[DEBUG_WALKABLE] narrow-strait intervening OVERRIDDEN (edgeTouch, falling through to raycasts) %s<->%s", tileA.Name, tileB.Name))
						end
					end
				end
			end
			-- CellToTilesMap empty/unavailable — no fast-path; continue with full checks
		end
	end

	local maxDistance = (mode == "aabb") and AABB_ADJACENCY_RESCUE_THRESHOLD or MAX_RASTER_ADJACENCY_DISTANCE
	if edgeDist > maxDistance then
		if DEBUG_REJECTED_ADJACENCY or DEBUG_WALKABLE_PAIR then
			warn(string.format("[DEBUG_WALKABLE] Rejected %s<->%s: edgeDist %.2f > maxDist %d (mode=%s)",
				tileA.Name, tileB.Name, edgeDist, maxDistance, mode))
		end
		if DEBUG_REJECTED_ADJACENCY then
			print(string.format("[TileAdjacencyManager] Rejected: %s <-> %s (edge distance %.1f > %d, %s mode)",
				tileA.Name, tileB.Name, edgeDist, maxDistance, mode))
		end
		return false
	end

	local rayHeight = math.max(closestA.Y, closestB.Y) + 20
	local heightDiff = math.abs(closestA.Y - closestB.Y)
	local rayLength = math.max(100, heightDiff + 50)

	-- FIX v21: When we fell through the narrow-strait override (tiles share edge
	-- contact but raster said intervening), filter raycasts to ONLY hit tileA and
	-- tileB geometry.  This prevents an actual intervening sliver tile from
	-- "providing ground" and fooling the walkability check.  For normal cases
	-- (no override), continue using the full EUROPE_MAP so the standard water/cliff
	-- detection works as before.
	local rayParams = RaycastParams.new()
	if narrowStraitOverride then
		rayParams.FilterDescendantsInstances = {tileA, tileB}
	else
		rayParams.FilterDescendantsInstances = {EUROPE_MAP}
	end
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
		return false
	end

	if maxConsecutiveMisses > MAX_CONSECUTIVE_MISSES then
		if DEBUG_REJECTED_ADJACENCY then
			print(string.format("[TileAdjacencyManager] Rejected (WATER): %s <-> %s (%d consecutive misses, distance: %.1f)",
				tileA.Name, tileB.Name, maxConsecutiveMisses, edgeDist))
		end
		return false
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
			return false
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

	return isWalkable
end

-- Finds the best walkable border crossing among top-k candidate boundary pairs.
-- Surface-corrects each candidate and revalidates the corrected segment inside the loop.
-- Returns {pointA, pointB, distance} of first walkable candidate, or nil.
local function _getBestWalkableBorderCrossing(tileA, tileB, k, mode)
	k = k or DEFAULT_CANDIDATE_K
	mode = mode or "raster"

	-- TEMP DEBUG: log all crossing attempts for specific problem pairs
	local DEBUG_THIS_PAIR = tileA and tileB and (
		(tileA.Name:find("Kujawsko") or tileB.Name:find("Kujawsko")) or
		(tileA.Name:find("Wielkopolskie") or tileB.Name:find("Wielkopolskie"))
	)

	local candidates
	if mode == "aabb" then
		candidates = _findCandidateEdgePointsBBox(tileA, tileB, k)
	else
		candidates = _findCandidateEdgePoints(tileA, tileB, k)
	end

	if not candidates or #candidates == 0 then
		if DEBUG_THIS_PAIR then
			warn(string.format("[DEBUG_PAIR] %s<->%s: no candidates (mode=%s)", tileA.Name, tileB.Name, mode))
		end
		return nil
	end

	if DEBUG_THIS_PAIR then
		warn(string.format("[DEBUG_PAIR] %s<->%s: %d candidates (mode=%s)", tileA.Name, tileB.Name, #candidates, mode))
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

		if DEBUG_THIS_PAIR then
			warn(string.format("[DEBUG_PAIR] candidate %d: rawDist=%.2f correctedDist=%.2f ptA=(%.1f,%.1f) ptB=(%.1f,%.1f)",
				i, candidate.distance, correctedDist, ptA.X, ptA.Z, ptB.X, ptB.Z))
		end

		-- Step 3: Validate the CORRECTED segment
		local walkable = isPathWalkable(tileA, tileB, {
			mode = mode,
			pointA = ptA,
			pointB = ptB,
			distance = correctedDist
		})
		if DEBUG_THIS_PAIR then
			warn(string.format("[DEBUG_PAIR] candidate %d: isPathWalkable=%s", i, tostring(walkable)))
		end
		if walkable then
			return { pointA = ptA, pointB = ptB, distance = correctedDist }
		end
	end

	if DEBUG_THIS_PAIR then
		warn(string.format("[DEBUG_PAIR] %s<->%s: ALL %d candidates FAILED (mode=%s)", tileA.Name, tileB.Name, #candidates, mode))
	end
	return nil
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

-- FIX v12.2: Strong intervening tile detection for Capital exceptions
-- Requires overwhelming evidence (75%+ samples) before rejecting adjacency
local function hasStrongInterveningTileBetweenBBox(tileA, tileB, cellToTilesLookup)
	local ptA, ptB, edgeDist = findClosestEdgePointsBBox(tileA, tileB)
	if not ptA or not ptB or edgeDist <= 0.5 then
		return false
	end
	
	-- Count how many sample points find intervening tiles
	local interveningCount = 0
	local totalSamples = 0

	-- Denser sampling: 7 fractions along edge-to-edge path
	for _, frac in ipairs({0.15, 0.25, 0.35, 0.5, 0.65, 0.75, 0.85}) do
		local sampleX = ptA.X + (ptB.X - ptA.X) * frac
		local sampleZ = ptA.Z + (ptB.Z - ptA.Z) * frac
		local sCx = math.floor(sampleX / RASTER_CELL_SIZE)
		local sCz = math.floor(sampleZ / RASTER_CELL_SIZE)
		local sKey = cellKey(sCx, sCz)
		local tilesAtSample = cellToTilesLookup[sKey]
		totalSamples = totalSamples + 1

		-- FIX v12.2: Each sample point contributes at most 1 to interveningCount
		local foundIntervening = false

		if tilesAtSample then
			for _, sTile in ipairs(tilesAtSample) do
				if sTile ~= tileA and sTile ~= tileB then
					foundIntervening = true
					break
				end
			end
		end
		-- Also check neighboring cells (in case sample is on a cell boundary)
		if not foundIntervening then
			for _, off in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
				if foundIntervening then break end
				local nKey = cellKey(sCx + off[1], sCz + off[2])
				local nTiles = cellToTilesLookup[nKey]
				if nTiles then
					for _, sTile in ipairs(nTiles) do
						if sTile ~= tileA and sTile ~= tileB then
							foundIntervening = true
							break
						end
					end
				end
			end
		end

		if foundIntervening then
			interveningCount = interveningCount + 1
		end
	end

	-- Only reject if overwhelming majority (75%+) of samples find intervening tiles
	return interveningCount > (totalSamples * 0.75)
end

-- FIX v12.1: Improved intervening tile detection - less aggressive rejection
-- Only reject adjacency if multiple samples find intervening tiles (not just one)
-- Returns true if multiple samples along the path find third tiles between tileA and tileB
hasInterveningTileBetween = function(tileA, tileB, cellToTilesLookup)
	local ptA, ptB, edgeDist = findClosestEdgePoints(tileA, tileB)
	if not ptA or not ptB or edgeDist <= 0.5 then
		return false
	end
	
	-- Count how many sample points find intervening tiles
	local interveningCount = 0
	local totalSamples = 0

	-- FIX v13: Expanded from 4 to 9 fractions, explicitly including the midpoint (0.5),
	-- which is the most diagnostic position for detecting thin intervening tiles.
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
					break -- Count each sample point only once
				end
			end
		end
		if foundIntervening then
			interveningCount = interveningCount + 1
		end
	end

	-- FIX v13: Perpendicular nudge samples at the midpoint (2 extra = 11 total).
	-- Resolves cell-boundary ambiguity at the most diagnostic position without
	-- adding noise across the entire path. Each nudge follows the same v12.2
	-- foundIntervening cap pattern (contributes at most 1 to interveningCount).
	local dx = ptB.X - ptA.X
	local dz = ptB.Z - ptA.Z
	local pathLen = math.sqrt(dx * dx + dz * dz)
	local nudge = RASTER_CELL_SIZE * 0.5  -- 1 stud when cell=2
	if pathLen > 0 then
		for _, nudgeSign in ipairs({1, -1}) do
			-- Perpendicular unit vector: rotate (dx, dz) by 90° → (-dz, dx)
			local nx = ptA.X + dx * 0.5 + (-dz / pathLen) * nudge * nudgeSign
			local nz = ptA.Z + dz * 0.5 + ( dx / pathLen) * nudge * nudgeSign
			local nCx = math.floor(nx / RASTER_CELL_SIZE)
			local nCz = math.floor(nz / RASTER_CELL_SIZE)
			local nKey = cellKey(nCx, nCz)
			local tilesAt = cellToTilesLookup[nKey]
			totalSamples = totalSamples + 1
			local found = false
			if tilesAt then
				for _, sTile in ipairs(tilesAt) do
					if sTile ~= tileA and sTile ~= tileB then
						found = true
						break
					end
				end
			end
			if found then
				interveningCount = interveningCount + 1
			end
		end
	end

	-- Only reject if majority of samples find intervening tiles (more than 50%).
	-- With 11 total samples, 6+ hits are needed to reject.
	-- totalSamples is used dynamically so the threshold self-adjusts if nudge is skipped (pathLen=0).
	local isRejected = interveningCount > (totalSamples / 2)

	-- FIX v13: Near-threshold diagnostic (DEBUG_INTERVENING_COUNTS must be true to enable).
	-- Only logs borderline cases (within 1 vote of the majority) to avoid log spam.
	if DEBUG_INTERVENING_COUNTS then
		local halfSamples = totalSamples / 2
		if interveningCount >= halfSamples - 1 and interveningCount <= halfSamples + 1 then
			print(string.format("[TileAdjacencyManager:Intervening] Near-threshold: %s <-> %s (%d/%d samples, %s)",
				tileA.Name, tileB.Name, interveningCount, totalSamples, isRejected and "REJECTED" or "accepted"))
		end
	end

	return isRejected
end

-- FIX v12.1: Improved BBox intervening tile detection - less aggressive rejection
-- Same logic as hasInterveningTileBetween but uses findClosestEdgePointsBBox
-- for more accurate edge points on tiles where rasterization missed border.
-- Only rejects if majority of samples find intervening tiles
local function hasInterveningTileBetweenBBox(tileA, tileB, cellToTilesLookup)
	local ptA, ptB, edgeDist = findClosestEdgePointsBBox(tileA, tileB)
	if not ptA or not ptB or edgeDist <= 0.5 then
		return false
	end
	
	-- Count how many sample points find intervening tiles
	local interveningCount = 0
	local totalSamples = 0

	-- Denser sampling: 7 fractions along edge-to-edge path
	for _, frac in ipairs({0.15, 0.25, 0.35, 0.5, 0.65, 0.75, 0.85}) do
		local sampleX = ptA.X + (ptB.X - ptA.X) * frac
		local sampleZ = ptA.Z + (ptB.Z - ptA.Z) * frac
		local sCx = math.floor(sampleX / RASTER_CELL_SIZE)
		local sCz = math.floor(sampleZ / RASTER_CELL_SIZE)
		local sKey = cellKey(sCx, sCz)
		local tilesAtSample = cellToTilesLookup[sKey]
		totalSamples = totalSamples + 1

		-- FIX v12.2 / v16: Each sample point contributes at most 1 to interveningCount.
		-- FIX v16: Removed neighbor-cell expansion — checking cardinal neighbors of each sample
		-- was causing false-positive intervening detections when the path runs near a third
		-- tile's corner (the neighbor cells of endpoint samples hit the third tile even when
		-- the straight-line path between A and B does not pass through it).
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

	-- Only reject if majority of samples find intervening tiles (more than 50%)
	return interveningCount > (totalSamples / 2)
end

-- AABB-based intervening tile check (FIX v19).
-- The raster-based hasInterveningTileBetween misses tiles that have rasterization gaps at
-- the crossing point (e.g. Basilicata between Campania and Calabria: its mesh doesn't reach
-- the two crossing raster cells, so interveningCount stays 0 regardless of the threshold).
-- This function checks each tile's axis-aligned bounding box against interior sample points
-- on the crossing segment, providing a reliable fallback.
-- NOTE: AABB overestimates rotated tiles but is conservative (more detections = fewer false
-- adjacencies), which is the correct direction of error for an intervening-tile guard.
hasInterveningTileByAABB = function(ptA, ptB, tileA, tileB)
	-- Segment AABB prefilter values
	local segMinX = math.min(ptA.X, ptB.X)
	local segMaxX = math.max(ptA.X, ptB.X)
	local segMinZ = math.min(ptA.Z, ptB.Z)
	local segMaxZ = math.max(ptA.Z, ptB.Z)

	-- Interior sample fractions only (avoid endpoints which sit on tileA/tileB boundaries)
	local FRACS = {0.25, 0.5, 0.75}

	for _, tileC in ipairs(AllTilesList) do
		if tileC == tileA or tileC == tileB then continue end

		local cPos = tileC.Position
		local cSize = tileC.Size
		local minX = cPos.X - cSize.X * 0.5
		local maxX = cPos.X + cSize.X * 0.5
		local minZ = cPos.Z - cSize.Z * 0.5
		local maxZ = cPos.Z + cSize.Z * 0.5

		-- Quick prefilter: segment bounding box must overlap tileC's AABB
		if segMaxX < minX or segMinX > maxX or segMaxZ < minZ or segMinZ > maxZ then
			continue
		end

		-- Full interior-point check
		for _, frac in ipairs(FRACS) do
			local sx = ptA.X + (ptB.X - ptA.X) * frac
			local sz = ptA.Z + (ptB.Z - ptA.Z) * frac
			if sx >= minX and sx <= maxX and sz >= minZ and sz <= maxZ then
				return true
			end
		end
	end
	return false
end

local function calculateAdjacenciesFromFootprints()
	narrowStraitFastPathCount = 0  -- Reset counter for this adjacency build
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
	local rejected = { distance = 0, intervening = 0, unwalkable = 0 }

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
								-- TEMP DEBUG: log raster stage entry for specific problem pairs
								local _debugRasterPair = (tileA.Name:find("Kujawsko") or tileB.Name:find("Kujawsko") or tileA.Name:find("Wielkopolskie") or tileB.Name:find("Wielkopolskie"))
								if _debugRasterPair then
									warn(string.format("[DEBUG_RASTER] %s<->%s edgeDist=%.2f maxAllowed=%d -> %s",
										tileA.Name, tileB.Name, edgeDist, MAX_RASTER_ADJACENCY_DISTANCE,
										edgeDist <= MAX_RASTER_ADJACENCY_DISTANCE and "PROCEEDING" or "DISTANCE_REJECTED"))
								end
								if edgeDist <= MAX_RASTER_ADJACENCY_DISTANCE then
									-- FIX v11/v12: Check for intervening tiles between candidates.
									local hasInterveningTile = hasInterveningTileBetween(tileA, tileB, CellToTilesLocal)
									if _debugRasterPair then
										warn(string.format("[DEBUG_RASTER] %s<->%s hasInterveningTile=%s",
											tileA.Name, tileB.Name, tostring(hasInterveningTile)))
									end
									-- FIX v21: When the raster intervening check fires but tiles physically
									-- touch (AABB edge distance == 0), the intervening detection is almost
									-- certainly a false positive caused by raster cell quantization.  The
									-- sampling path between boundary-cell centers can clip through a third
									-- tile's cells even though no tile actually sits between A and B.
									-- Override with a stricter "strong" check (75% threshold) that is much
									-- less susceptible to corner clipping.  This resolves widespread false
									-- rejections across the Europe map (e.g. Etelä-Karjala<->Kymenlaakso).
									if hasInterveningTile then
										local edgeTouch = aabbEdgeTouchXZ(tileA, tileB)
										if edgeTouch then
											-- Tiles share a real AABB edge contact — raster sampling
											-- path is unreliable here because boundary-cell centers can
											-- be offset from the real border, clipping through a third
											-- tile's cells.  Fall back to the strong (75%) BBox-based
											-- check which requires overwhelming evidence before rejecting.
											hasInterveningTile = hasStrongInterveningTileBetweenBBox(tileA, tileB, CellToTilesLocal)
											if _debugRasterPair or DEBUG_REJECTED_ADJACENCY then
												warn(string.format("[TileAdjacencyManager] Raster intervening override (edgeTouch): %s <-> %s, strong check = %s",
													tileA.Name, tileB.Name, tostring(hasInterveningTile)))
											end
										end
									end
									if hasInterveningTile and DEBUG_REJECTED_ADJACENCY then
										print(string.format("[TileAdjacencyManager] Rejected raster adjacency (intervening tile): %s <-> %s (edge distance %.1f)",
											tileA.Name, tileB.Name, edgeDist))
									end
									if not hasInterveningTile then
										-- Top-k walkable border crossing: try up to k candidates along shared border
										local bestCrossing = _getBestWalkableBorderCrossing(tileA, tileB, DEFAULT_CANDIDATE_K, "raster")
										if bestCrossing then
											table.insert(AdjacentTiles[tileA], tileB)
											if not AdjacentTiles[tileB] then AdjacentTiles[tileB] = {} end
											table.insert(AdjacentTiles[tileB], tileA)

											-- Store proof: raster-based adjacency with walkable crossing points
											if not AdjacencyProof[tileA] then AdjacencyProof[tileA] = {} end
											if not AdjacencyProof[tileB] then AdjacencyProof[tileB] = {} end
											AdjacencyProof[tileA][tileB] = { mode = "raster", pointA = bestCrossing.pointA, pointB = bestCrossing.pointB, distance = bestCrossing.distance }
											AdjacencyProof[tileB][tileA] = { mode = "raster", pointA = bestCrossing.pointB, pointB = bestCrossing.pointA, distance = bestCrossing.distance }
										else
											rejected.unwalkable = rejected.unwalkable + 1
											if DEBUG_REJECTED_ADJACENCY then
												print(string.format("[TileAdjacencyManager] Rejected raster adjacency (no walkable crossing, %d candidates tried): %s <-> %s (closest edge dist %.1f)",
													DEFAULT_CANDIDATE_K, tileA.Name, tileB.Name, edgeDist))
											end
										end
									else
										rejected.intervening = rejected.intervening + 1
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
	print(string.format("[TileAdjacencyManager] Rasterization adjacency complete: %d connections, avg %.1f per tile (rejected: distance=%d, intervening=%d, unwalkable=%d, narrow-strait=%d)",
		totalConnections, avgConnections, rejected.distance, rejected.intervening, rejected.unwalkable, narrowStraitFastPathCount))

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

-- FIX v9.3: Extended adjacencies with stricter water detection
local function calculateExtendedAdjacencies()
	if EXTENDED_ADJACENCY_THRESHOLD <= 0 then
		print("[TileAdjacencyManager] Extended adjacency disabled (threshold <= 0)")
		return
	end

	local extendedCount = 0
	local rejectedCount = 0
	local rejectedReasons = {
		distance = 0,
		intervening = 0,
		unwalkable = 0,
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

	-- Build quick lookup of existing adjacencies
	local existingAdjacent = {}
	for tileA, neighbors in pairs(AdjacentTiles) do
		existingAdjacent[tileA] = existingAdjacent[tileA] or {}
		for _, tileB in ipairs(neighbors) do
			existingAdjacent[tileA][tileB] = true
			existingAdjacent[tileB] = existingAdjacent[tileB] or {}
			existingAdjacent[tileB][tileA] = true
		end
	end

	-- Check all tile pairs for extended adjacency (tiles with small gaps) and narrow straits
	local adjacencyThreshold = math.max(EXTENDED_ADJACENCY_THRESHOLD, AABB_ADJACENCY_RESCUE_THRESHOLD, NARROW_STRAIT_THRESHOLD)
	for i = 1, #AllTilesList do
		local tileA = AllTilesList[i]
		local halfDiagA = 0.5 * math.sqrt(tileA.Size.X * tileA.Size.X + tileA.Size.Z * tileA.Size.Z)

		for j = i + 1, #AllTilesList do
			local tileB = AllTilesList[j]

			-- Skip if already adjacent (from rasterization)
			if existingAdjacent[tileA] and existingAdjacent[tileA][tileB] then
				continue
			end

			-- Quick XZ center-to-center prefilter: skip pairs where adjacency is geometrically impossible.
			-- Uses XZ half-diagonals (not 3D Size.Magnitude) so tall tiles don't inflate the bound.
			local diff = tileA.Position - tileB.Position
			local centerDistXZ = math.sqrt(diff.X * diff.X + diff.Z * diff.Z)
			local halfDiagB = 0.5 * math.sqrt(tileB.Size.X * tileB.Size.X + tileB.Size.Z * tileB.Size.Z)
			local maxPossibleProximity = halfDiagA + halfDiagB + adjacencyThreshold
			if centerDistXZ > maxPossibleProximity then
				continue
			end

			-- FIX v12: Two-path adjacency check using both raster and AABB distances
			-- FIX v19: Capture raster edge points so Path A can run the AABB intervening check
			local rasterPtA, rasterPtB, rasterEdgeDistance = findClosestEdgePoints(tileA, tileB)
			local aabbEdgeDistance = calculateEdgeDistance(tileA, tileB)

			local shouldConnect = false

			-- FIX v12.2: Diagnostic logging for specific tile pairs (remove after verification)
			local DEBUG_PAIR = (tileA.Name == "Vordingborg Kommune" and tileB.Name == "Næstved Kommune")
				or (tileA.Name == "Næstved Kommune" and tileB.Name == "Vordingborg Kommune")
			if DEBUG_PAIR then
				warn(string.format("[DEBUG PAIR] %s <-> %s | rasterEdgeDist: %.2f | aabbEdgeDist: %.2f | centerDist: %.2f",
					tileA.Name, tileB.Name, rasterEdgeDistance, aabbEdgeDistance, centerDistXZ))
			end

			-- Path A: Original gap-bridging logic (raster-based distance)
			if rasterEdgeDistance > 0 and rasterEdgeDistance <= EXTENDED_ADJACENCY_THRESHOLD then
				-- FIX v19: Path A previously had NO intervening tile check, unlike Path B.
				-- Add raster + AABB intervening tile guards before accepting any connection.
				-- This prevents tiles separated by a thin/un-rasterized neighbour (e.g. Basilicata
				-- between Campania and Calabria) from being falsely connected via Path A.
				local hasIntervening = hasInterveningTileBetween(tileA, tileB, CellToTilesMap)
				if not hasIntervening then
					-- FIX v19: Use tile CENTERS (not boundary points) for the AABB check.
					-- Center-to-center samples the actual geographic corridor between regions,
					-- not just the narrow 2.8-stud raster corner where boundary cells happened
					-- to sit. This reliably catches Basilicata between Campania/Calabria
					-- (its AABB covers the center-midpoint at ~(27.9, 54.1)) while avoiding
					-- false positives for Swiss side-neighbors whose centers are off to the side.
					hasIntervening = hasInterveningTileByAABB(tileA.Position, tileB.Position, tileA, tileB)
				end
				if hasIntervening then
					rejectedCount = rejectedCount + 1
					rejectedReasons.intervening = rejectedReasons.intervening + 1
					if DEBUG_REJECTED_ADJACENCY then
						print(string.format("[TileAdjacencyManager] Path A rejected (intervening tile): %s <-> %s (raster: %.1f)",
							tileA.Name, tileB.Name, rasterEdgeDistance))
					end
				else
				-- Top-k walkable border crossing for gap-bridging
				local bestCrossing = _getBestWalkableBorderCrossing(tileA, tileB, DEFAULT_CANDIDATE_K, "raster")
				if bestCrossing then
					shouldConnect = true

					-- Store proof: raster gap-bridge with walkable crossing points
					if not AdjacencyProof[tileA] then AdjacencyProof[tileA] = {} end
					if not AdjacencyProof[tileB] then AdjacencyProof[tileB] = {} end
					AdjacencyProof[tileA][tileB] = { mode = "raster", pointA = bestCrossing.pointA, pointB = bestCrossing.pointB, distance = bestCrossing.distance }
					AdjacencyProof[tileB][tileA] = { mode = "raster", pointA = bestCrossing.pointB, pointB = bestCrossing.pointA, distance = bestCrossing.distance }
				else
					rejectedCount = rejectedCount + 1
					rejectedReasons.unwalkable = rejectedReasons.unwalkable + 1
				end
			end  -- close Path A else (no intervening tile)
			-- Path B: AABB rescue for short-border tiles missed by rasterization
			-- Tiles are geometrically touching/close but raster cells didn't align at border
			-- FIX v12.1: Now requires BOTH walkability AND no intervening tile
			-- Walkability alone is insufficient: land tiles separated by other tiles pass raycasts
			-- (ground exists everywhere) but should NOT be adjacent because another tile is between them.
			elseif aabbEdgeDistance <= AABB_ADJACENCY_RESCUE_THRESHOLD then
				-- Step 1: Check for intervening tiles (use bbox first, raster as second opinion)
				local hasIntervening = hasInterveningTileBetweenBBox(tileA, tileB, CellToTilesMap)
				if DEBUG_PAIR then
					warn(string.format("[DEBUG PAIR]   Path B: BBox intervening = %s", tostring(hasIntervening)))
				end
			
				if not hasIntervening then
					-- second opinion: raster-based check
					hasIntervening = hasInterveningTileBetween(tileA, tileB, CellToTilesMap)
					if DEBUG_PAIR then
						warn(string.format("[DEBUG PAIR]   Path B: raster intervening (2nd opinion) = %s", tostring(hasIntervening)))
					end
				end
			
				if hasIntervening then
					-- There's something between A and B; reject rescue
					rejectedCount = rejectedCount + 1
					rejectedReasons.intervening = rejectedReasons.intervening + 1
					if DEBUG_REJECTED_ADJACENCY then
						print(string.format("[TileAdjacencyManager] AABB rescue rejected (intervening tile): %s <-> %s (AABB: %.1f, raster: %.1f)",
								tileA.Name, tileB.Name, aabbEdgeDistance, rasterEdgeDistance))
					end
			
				else
					-- Step 2: Find top-k walkable border crossing candidates (AABB)
					local bestCrossing = _getBestWalkableBorderCrossing(tileA, tileB, DEFAULT_CANDIDATE_K, "aabb")
			
					if bestCrossing then
						-- Enforce a strict distance gate to avoid bridging real gaps
						-- (If the crossing is more than 2 studs it's likely a gap, not a misalignment)
						if bestCrossing.distance <= 2.0 then
							shouldConnect = true
			
							-- Store proof: AABB rescue with walkable crossing points
							AdjacencyProof[tileA] = AdjacencyProof[tileA] or {}
							AdjacencyProof[tileB] = AdjacencyProof[tileB] or {}
							AdjacencyProof[tileA][tileB] = {
								mode = "aabb",
								pointA = bestCrossing.pointA,
								pointB = bestCrossing.pointB,
								distance = bestCrossing.distance
							}
							AdjacencyProof[tileB][tileA] = {
								mode = "aabb",
								pointA = bestCrossing.pointB,
								pointB = bestCrossing.pointA,
								distance = bestCrossing.distance
							}
			
							if DEBUG_EXTENDED_ADJACENCY then
								print(string.format("[TileAdjacencyManager] AABB rescue adjacency: %s <-> %s (AABB: %.1f, raster: %.1f, crossing: %.2f)",
										tileA.Name, tileB.Name, aabbEdgeDistance, rasterEdgeDistance, bestCrossing.distance))
							end
			
						else
							-- Candidate crossing exists but gap too large — treat as rejected gap
							rejectedCount = rejectedCount + 1
							rejectedReasons.distance = rejectedReasons.distance + 1
							if DEBUG_REJECTED_ADJACENCY then
								print(string.format("[Adjacency] AABB Rejected: Gap too large (%.2f studs) between %s and %s (AABB: %.1f, raster: %.1f)",
										bestCrossing.distance, tileA.Name, tileB.Name, aabbEdgeDistance, rasterEdgeDistance))
							end
						end
			
					else
						-- No walkable candidate found within DEFAULT_CANDIDATE_K
						rejectedCount = rejectedCount + 1
						rejectedReasons.unwalkable = rejectedReasons.unwalkable + 1
						if DEBUG_REJECTED_ADJACENCY then
							print(string.format("[TileAdjacencyManager] AABB rescue rejected (unwalkable, %d candidates tried): %s <-> %s (AABB: %.1f, raster: %.1f)",
									DEFAULT_CANDIDATE_K, tileA.Name, tileB.Name, aabbEdgeDistance, rasterEdgeDistance))
						end
					end
				end
			end

			-- Path C: Narrow strait crossing (wider than Path A/B thresholds)
			-- Handles real-world straits like Schleswig-Holstein→Denmark where tiles are
			-- separated by water gaps of 3-8 studs. The narrow-strait fast-path inside
			-- isPathWalkable will approve the crossing if there's no intervening tile.
			if not shouldConnect and rasterEdgeDistance > 0 and rasterEdgeDistance <= NARROW_STRAIT_THRESHOLD
				and rasterEdgeDistance > EXTENDED_ADJACENCY_THRESHOLD then
				-- Only enter Path C for gaps wider than what Path A already handled
				local hasIntervening = hasInterveningTileBetween(tileA, tileB, CellToTilesMap)
				if not hasIntervening then
					-- FIX v20: Use raster edge points (rasterPtA/rasterPtB) rather than tile CENTERS
					-- for the AABB intervening-tile check in Path C (narrow strait crossings).
					--
					-- WHY centers were broken here:
					-- Large neighbouring tiles (e.g. Region Sydvestdanmark, Hamburg) have wide AABBs
					-- that span the center-to-center corridor between two strait tiles.  The center
					-- check was therefore detecting them as "intervening" and blocking valid straits
					-- such as Syddanmark↔Sydøstdanmark (blocked by Sydvestdanmark's AABB) and
					-- Schleswig-Holstein↔Lolland (blocked by Hamburg's AABB).
					--
					-- WHY edge points are safe here:
					-- rasterPtA and rasterPtB are the nearest actual shoreline raster cells of each
					-- tile.  Sampling along THIS segment checks only the water corridor of the strait.
					-- No legitimate land tile sits in that narrow water gap, so the check correctly
					-- returns false.  The raster-based hasInterveningTileBetween (run above) already
					-- guards against any land tile whose raster cells appear in the corridor — the
					-- AABB check is a secondary guard for tiles whose mesh has rasterisation gaps.
					-- For water crossings there are no such tiles, so using edge points is safe.
					--
					-- NOTE: Path A (land gap ≤ 3 studs) intentionally keeps the center-based check
					-- to preserve the FIX v19 Basilicata guard.
					hasIntervening = hasInterveningTileByAABB(rasterPtA, rasterPtB, tileA, tileB)
				end
				if not hasIntervening then
					-- Use the narrow-strait fast-path in isPathWalkable (which skips water checks)
					local bestCrossing = _getBestWalkableBorderCrossing(tileA, tileB, DEFAULT_CANDIDATE_K, "raster")
					if bestCrossing then
						shouldConnect = true
						narrowStraitFastPathCount = narrowStraitFastPathCount + 1

						-- Store proof
						if not AdjacencyProof[tileA] then AdjacencyProof[tileA] = {} end
						if not AdjacencyProof[tileB] then AdjacencyProof[tileB] = {} end
						AdjacencyProof[tileA][tileB] = { mode = "raster", pointA = bestCrossing.pointA, pointB = bestCrossing.pointB, distance = bestCrossing.distance }
						AdjacencyProof[tileB][tileA] = { mode = "raster", pointA = bestCrossing.pointB, pointB = bestCrossing.pointA, distance = bestCrossing.distance }

						if DEBUG_EXTENDED_ADJACENCY or DEBUG_REJECTED_ADJACENCY then
							print(string.format("[TileAdjacencyManager] Narrow-strait adjacency: %s <-> %s (raster: %.1f, crossing: %.2f)",
								tileA.Name, tileB.Name, rasterEdgeDistance, bestCrossing.distance))
						end
					else
						rejectedCount = rejectedCount + 1
						rejectedReasons.unwalkable = rejectedReasons.unwalkable + 1
						if DEBUG_REJECTED_ADJACENCY then
							print(string.format("[TileAdjacencyManager] Narrow-strait rejected (unwalkable): %s <-> %s (raster: %.1f)",
								tileA.Name, tileB.Name, rasterEdgeDistance))
						end
					end
				else
					rejectedCount = rejectedCount + 1
					rejectedReasons.intervening = rejectedReasons.intervening + 1
					if DEBUG_REJECTED_ADJACENCY then
						print(string.format("[TileAdjacencyManager] Narrow-strait rejected (intervening tile): %s <-> %s (raster: %.1f)",
							tileA.Name, tileB.Name, rasterEdgeDistance))
					end
				end
			end

			if DEBUG_PAIR then
				warn(string.format("[DEBUG PAIR]   Final result: shouldConnect = %s", tostring(shouldConnect)))
			end

			if shouldConnect then
				if addAdjacency(tileA, tileB, existingAdjacent) then
					extendedCount = extendedCount + 1
					if DEBUG_EXTENDED_ADJACENCY then
						print(string.format("[TileAdjacencyManager] Extended adjacency: %s <-> %s (raster: %.1f, AABB: %.1f)",
							tileA.Name, tileB.Name, rasterEdgeDistance, aabbEdgeDistance))
					end
				end
			end
		end

		-- Yield occasionally to prevent timeout
		if i % 50 == 0 then
			task.wait(0)
		end
	end

	print(string.format("[TileAdjacencyManager] Extended adjacency: added %d connections, rejected %d (intervening=%d, unwalkable=%d, distance=%d)",
		extendedCount, rejectedCount,
		rejectedReasons.intervening, rejectedReasons.unwalkable, rejectedReasons.distance))
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

-- FIX v12.2: Runtime diagnostic for adjacency failures - re-runs all checks and reports results
function TileAdjacencyManager.diagnoseAdjacency(tileA, tileB)
	if not tileA or not tileB then
		warn("[ADJACENCY DIAG] One or both tiles are nil")
		return
	end

	warn("=== ADJACENCY DIAGNOSTIC: " .. tileA.Name .. " <-> " .. tileB.Name .. " ===")

	-- Check if tile parts are in the tile data
	local footprintA = TileFootprint[tileA]
	local footprintB = TileFootprint[tileB]
	local cellCountA = 0
	local cellCountB = 0
	if footprintA then for _ in pairs(footprintA) do cellCountA = cellCountA + 1 end end
	if footprintB then for _ in pairs(footprintB) do cellCountB = cellCountB + 1 end end
	warn(string.format("  Raster footprint: %s has %d cells, %s has %d cells", tileA.Name, cellCountA, tileB.Name, cellCountB))

	if cellCountA == 0 or cellCountB == 0 then
		warn("  ❌ PROBLEM: One or both tiles have no raster footprint! Tile may not be registered.")
		-- Check if tile is in AllTilesList
		local foundA, foundB = false, false
		for _, t in ipairs(AllTilesList) do
			if t == tileA then foundA = true end
			if t == tileB then foundB = true end
		end
		warn(string.format("  In AllTilesList: %s=%s, %s=%s", tileA.Name, tostring(foundA), tileB.Name, tostring(foundB)))
		return
	end

	-- Check distances
	local centerDistXZ = ((tileA.Position - tileB.Position) * Vector3.new(1, 0, 1)).Magnitude
	local rasterDiagPtA, rasterDiagPtB, rasterEdgeDist = findClosestEdgePoints(tileA, tileB)
	local aabbEdgeDist = calculateEdgeDistance(tileA, tileB)
	warn(string.format("  Center-to-center (XZ): %.2f studs", centerDistXZ))
	warn(string.format("  Raster edge distance: %.2f studs", rasterEdgeDist))
	warn(string.format("  AABB edge distance: %.2f studs", aabbEdgeDist))
	warn(string.format("  Tile A size: (%.1f, %.1f, %.1f) | Tile B size: (%.1f, %.1f, %.1f)",
		tileA.Size.X, tileA.Size.Y, tileA.Size.Z, tileB.Size.X, tileB.Size.Y, tileB.Size.Z))
	warn(string.format("  Tile A pos: (%.1f, %.1f, %.1f) | Tile B pos: (%.1f, %.1f, %.1f)",
		tileA.Position.X, tileA.Position.Y, tileA.Position.Z, tileB.Position.X, tileB.Position.Y, tileB.Position.Z))

	-- Check raster adjacency: do they share grid neighbors?
	local shareGridNeighbor = false
	if footprintA and footprintB then
		for key, _ in pairs(footprintA) do
			local cx, cz = parseCellKey(key)
			if cx then
				for _, offset in ipairs(NEIGHBOR_OFFSETS) do
					local nKey = cellKey(cx + offset[1], cz + offset[2])
					if footprintB[nKey] then
						shareGridNeighbor = true
						break
					end
				end
			end
			if shareGridNeighbor then break end
		end
	end
	warn(string.format("  Share grid neighbor cells: %s", tostring(shareGridNeighbor)))

	if shareGridNeighbor then
		-- They should have been caught by raster adjacency
		-- Check if intervening tile blocked them
		local hasIntervening = hasInterveningTileBetween(tileA, tileB, CellToTilesMap)
		warn(string.format("  Raster stage intervening tile check: %s", tostring(hasIntervening)))
		-- FIX v21: Mirror the raster-stage override — if tiles touch (AABB=0) and raster
		-- says intervening, re-check with the strong (75%) BBox check.
		if hasIntervening then
			local edgeTouchDiag = aabbEdgeTouchXZ(tileA, tileB)
			warn(string.format("  FIX v21 edge-touch check: %s", tostring(edgeTouchDiag)))
			if edgeTouchDiag then
				local strongResult = hasStrongInterveningTileBetweenBBox(tileA, tileB, CellToTilesMap)
				warn(string.format("  FIX v21 override (edgeTouch): strong BBox check = %s", tostring(strongResult)))
				hasIntervening = strongResult
			end
		end
		if hasIntervening then
			warn("  ❌ BLOCKED at raster stage by intervening tile check")
		elseif rasterEdgeDist > MAX_RASTER_ADJACENCY_DISTANCE then
			warn(string.format("  ❌ BLOCKED at raster stage: edge distance %.2f > MAX_RASTER_ADJACENCY_DISTANCE %d", rasterEdgeDist, MAX_RASTER_ADJACENCY_DISTANCE))
		else
			warn("  ⚠️ Unknown reason for raster stage rejection despite sharing grid neighbors")
			-- Run walkability check to expose the actual blocker
			local bestCrossing = _getBestWalkableBorderCrossing(tileA, tileB, DEFAULT_CANDIDATE_K, "raster")
			if bestCrossing then
				warn(string.format("  ✅ Walkability check passes NOW (ptA=%.1f,%.1f ptB=%.1f,%.1f dist=%.2f) — adjacency rebuild should fix this",
					bestCrossing.pointA.X, bestCrossing.pointA.Z, bestCrossing.pointB.X, bestCrossing.pointB.Z, bestCrossing.distance))
			else
				warn("  ❌ Walkability check failed — no walkable border crossing found (raster mode)")
			end
		end
	else
		warn("  → No shared grid neighbors, would need extended adjacency")
	end

	-- Check extended adjacency Path A
	local pathACondition = rasterEdgeDist > 0 and rasterEdgeDist <= EXTENDED_ADJACENCY_THRESHOLD
	warn(string.format("  Path A condition (rasterEdgeDist > 0 AND <= %d): %s (rasterEdgeDist=%.2f)",
		EXTENDED_ADJACENCY_THRESHOLD, tostring(pathACondition), rasterEdgeDist))
	if pathACondition then
		local walkable = isPathWalkable(tileA, tileB)
		warn(string.format("  Path A walkability: %s", tostring(walkable)))
		if not walkable then
			warn("  ❌ BLOCKED at Path A: walkability check failed")
		end
	end

	-- Check extended adjacency Path B
	local pathBCondition = aabbEdgeDist <= AABB_ADJACENCY_RESCUE_THRESHOLD
	warn(string.format("  Path B condition (aabbEdgeDist <= %d): %s (aabbEdgeDist=%.2f)",
		AABB_ADJACENCY_RESCUE_THRESHOLD, tostring(pathBCondition), aabbEdgeDist))
	if pathBCondition and not pathACondition then
		local hasBBoxIntervening = hasInterveningTileBetweenBBox(tileA, tileB, CellToTilesMap)
		warn(string.format("  Path B BBox intervening: %s", tostring(hasBBoxIntervening)))
		if not hasBBoxIntervening then
			local hasRasterIntervening = hasInterveningTileBetween(tileA, tileB, CellToTilesMap)
			warn(string.format("  Path B raster intervening (2nd opinion): %s", tostring(hasRasterIntervening)))
			if not hasRasterIntervening then
				local walkable = isPathWalkable(tileA, tileB, { mode = "aabb" })
				warn(string.format("  Path B walkability (aabbOverride): %s", tostring(walkable)))
				if not walkable then
					warn("  ❌ BLOCKED at Path B: walkability check failed")
				else
					warn("  ✅ Path B should have connected these tiles!")
				end
			else
				warn("  ❌ BLOCKED at Path B: raster intervening tile (2nd opinion)")
			end
		else
			warn("  ❌ BLOCKED at Path B: BBox intervening tile check")
		end
	elseif not pathBCondition then
		warn(string.format("  ❌ Path B not entered: aabbEdgeDist %.2f > threshold %d", aabbEdgeDist, AABB_ADJACENCY_RESCUE_THRESHOLD))
	end

	-- Check extended adjacency Path C (narrow strait)
	local pathCCondition = rasterEdgeDist > 0 and rasterEdgeDist <= NARROW_STRAIT_THRESHOLD
		and rasterEdgeDist > EXTENDED_ADJACENCY_THRESHOLD
	warn(string.format("  Path C condition (narrow strait, rasterEdgeDist in (%d, %d]): %s (rasterEdgeDist=%.2f)",
		EXTENDED_ADJACENCY_THRESHOLD, NARROW_STRAIT_THRESHOLD, tostring(pathCCondition), rasterEdgeDist))
	if pathCCondition then
		local hasIntervening = hasInterveningTileBetween(tileA, tileB, CellToTilesMap)
		warn(string.format("  Path C raster intervening: %s", tostring(hasIntervening)))
		if not hasIntervening then
			hasIntervening = hasInterveningTileByAABB(rasterDiagPtA, rasterDiagPtB, tileA, tileB)
			warn(string.format("  Path C AABB intervening (edge-points): %s", tostring(hasIntervening)))
		end
		if not hasIntervening then
			local bestCrossing = _getBestWalkableBorderCrossing(tileA, tileB, DEFAULT_CANDIDATE_K, "raster")
			if bestCrossing then
				warn(string.format("  ✅ Path C should have connected these tiles! (crossing: %.2f)", bestCrossing.distance))
			else
				warn("  ❌ BLOCKED at Path C: no walkable crossing found (narrow strait)")
			end
		else
			warn("  ❌ BLOCKED at Path C: intervening tile detected")
		end
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

---------------------------------------------------
-- Explicit strait connections (fundamental fix)
---------------------------------------------------

-- Registers every pair in STRAIT_CONNECTIONS as adjacent unconditionally.
-- Called after calculateExtendedAdjacencies() so it can fill in crossings
-- that the geometric detection paths (A/B/C) cannot handle.
--
-- Each registered pair gets:
--   • An entry in AdjacentTiles (bidirectional)
--   • An AdjacencyProof with mode="raster" and the closest-edge waypoints
--     (computed by findClosestEdgePointsBBox, which is AABB-safe regardless
--     of whether raster footprints exist for the pair).
--
-- The proof mode is "raster" so that isPathWalkable's narrow-strait fast-path
-- applies at movement time, bypassing the water-crossing raycasts.
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
				-- Mode "raster" ensures isPathWalkable uses its narrow-strait fast-path,
				-- which skips water raycasts for pairs within NARROW_STRAIT_THRESHOLD.
				AdjacencyProof[tileA] = AdjacencyProof[tileA] or {}
				AdjacencyProof[tileB] = AdjacencyProof[tileB] or {}
				AdjacencyProof[tileA][tileB] = {
					mode = "raster",
					pointA = ptA,
					pointB = ptB,
					distance = dist,
				}
				AdjacencyProof[tileB][tileA] = {
					mode = "raster",
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
-- Returns: { mode: "raster"|"aabb", pointA: Vector3, pointB: Vector3, distance: number } or nil
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
