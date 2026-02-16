-- TileAdjacencyManager (ModuleScript in ServerScriptService) - v12.2 INTERVENING TILE COUNT FIX
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
local ADJACENCY_ALLOW_DIAGONAL = true
local DEBUG = false
local BATCH_YIELD_AFTER = 80       -- yield after this many tiles while rasterizing (set 0 to disable)

-- FIX v9.5: Maximum distance for rasterization adjacencies
-- Even if cells are grid neighbors, tiles must be within this edge distance to be adjacent
-- INCREASED from 6 to 12 studs to accommodate map scale and tile spacing
local MAX_RASTER_ADJACENCY_DISTANCE = 12  -- studs (prevents false adjacencies on small/complex tiles)

-- Extended adjacency configuration (fixes gaps and validates diagonals)
-- INCREASED from 1.5 to 4 studs to allow more gap-bridging adjacencies
local EXTENDED_ADJACENCY_THRESHOLD = 4  -- max edge-to-edge distance (studs) to consider adjacent
-- local VALIDATE_EXTENDED_ONLY = true     -- FIX v9.2: Only validate EXTENDED adjacencies, trust rasterization
local DEBUG_EXTENDED_ADJACENCY = false  -- enable to see which pairs get extended adjacency
local DEBUG_REJECTED_ADJACENCY = true   -- FIX v9.3: Debug which adjacencies are rejected (enabled for testing)

-- FIX v12: AABB-based adjacency rescue for tiles with short shared borders
-- Catches tiles that touch geometrically but were missed by rasterization
-- INCREASED from 6 to 12 studs to match MAX_RASTER_ADJACENCY_DISTANCE
local AABB_ADJACENCY_RESCUE_THRESHOLD = 12  -- studs, matches MAX_RASTER_ADJACENCY_DISTANCE

-- FIX v9.3: Stricter water detection thresholds
local GROUND_RATIO_THRESHOLD = 0.85     -- Require 85% ground coverage (up from 60%)
local MAX_CONSECUTIVE_MISSES = 1        -- If 2+ consecutive points miss ground, it's a water gap

-- Data structures
local TileParts = {}       -- TileParts[countryName] = { BasePart, ... }
local AdjacentTiles = {}   -- AdjacentTiles[tile] = { neighborPart, ... }
local PositionToTile = {}  -- PositionToTile["x,z"] = BasePart
local AllTilesList = {}    -- flat array of all tile parts

-- Rasterization data
local TileFootprint = {}   -- TileFootprint[tile] = { ["cx,cz"] = true, ... }
local CellToTile = {}      -- CellToTile["cx,cz"] = tile (first tile found at this cell) - optional
local TileSafeCenter = {}  -- TileSafeCenter[tile] = Vector3 (rasterization centroid, safe from edges)
local CellToTilesMap = {}  -- FIX v12: Cell -> list of tiles, populated during adjacency calc, used by extended adjacency

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

-- Calculate minimum edge-to-edge distance between two tiles (XZ plane only)
-- Returns the closest distance between any edges of the two tile bounding boxes
local function calculateEdgeDistance(tileA, tileB)
	local cfA = tileA.CFrame
	local cfB = tileB.CFrame
	local halfA = tileA.Size / 2
	local halfB = tileB.Size / 2

	-- Get world-space bounding boxes (axis-aligned approximation)
	local minAX, maxAX = math.huge, -math.huge
	local minAZ, maxAZ = math.huge, -math.huge
	local minBX, maxBX = math.huge, -math.huge
	local minBZ, maxBZ = math.huge, -math.huge

	-- Project corners to find AABB
	for sx = -1, 1, 2 do
		for sy = -1, 1, 2 do
			for sz = -1, 1, 2 do
				local cornerA = cfA:PointToWorldSpace(Vector3.new(sx * halfA.X, sy * halfA.Y, sz * halfA.Z))
				local cornerB = cfB:PointToWorldSpace(Vector3.new(sx * halfB.X, sy * halfB.Y, sz * halfB.Z))

				minAX = math.min(minAX, cornerA.X); maxAX = math.max(maxAX, cornerA.X)
				minAZ = math.min(minAZ, cornerA.Z); maxAZ = math.max(maxAZ, cornerA.Z)
				minBX = math.min(minBX, cornerB.X); maxBX = math.max(maxBX, cornerB.X)
				minBZ = math.min(minBZ, cornerB.Z); maxBZ = math.max(maxBZ, cornerB.Z)
			end
		end
	end

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

	if rawCellDist < 0.5 and actualTileDistance > 10 then
		-- Boundary cells overlap/touch, but tiles are far apart - use AABB instead
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

-- FIX v9.3: Stricter walkability check for EXTENDED adjacencies
-- FIX v9.4: Allow close tiles (within EXTENDED_ADJACENCY_THRESHOLD) to traverse water
-- FIX v12: Added aabbOverride parameter for AABB rescue path
-- Now uses:
--   1. Higher ground ratio (85% instead of 60%)
--   2. Consecutive gap detection (2+ misses = water crossing)
--   3. Explicit midpoint check
--   4. EXCEPTION: Tiles within 3 studs are always walkable (NPCs can jump small gaps)
--   5. AABB override: when called from AABB rescue, use AABB edge points if raster fails
local function isPathWalkable(tileA, tileB, aabbOverride)
	-- Find the closest points between the two tiles
	local closestA, closestB, edgeDist = findClosestEdgePoints(tileA, tileB)

	-- FIX v9.4: If tiles are close enough (within extended adjacency threshold),
	-- allow traversal even over water - NPCs can walk/jump small gaps
	if edgeDist <= EXTENDED_ADJACENCY_THRESHOLD then
		if DEBUG_EXTENDED_ADJACENCY then
			print(string.format("[TileAdjacencyManager] Allowed close adjacency: %s <-> %s (%.1f studs, within threshold)",
				tileA.Name, tileB.Name, edgeDist))
		end
		return true
	end

	-- FIX v12.2: For AABB rescue path, if raster edge distance exceeds the walkability bypass
	-- threshold, fall back to AABB edge points for raycasting. Raster boundary cell centers can
	-- be far apart (crossing water) even when tiles physically touch (AABB overlap).
	-- Previously this only triggered at edgeDist > 6, missing cases like 4.47 studs where
	-- raster points cross water but AABB distance is 0 (tiles overlap).
	if aabbOverride and edgeDist > EXTENDED_ADJACENCY_THRESHOLD then
		local rasterDist = edgeDist
		local bboxA, bboxB, bboxDist = findClosestEdgePointsBBox(tileA, tileB)
		if bboxDist <= EXTENDED_ADJACENCY_THRESHOLD then
			-- AABB says tiles are close enough to bypass walkability entirely
			if DEBUG_EXTENDED_ADJACENCY then
				print(string.format("[TileAdjacencyManager] AABB override bypass: %s <-> %s (bbox: %.1f <= threshold, raster was: %.1f)",
					tileA.Name, tileB.Name, bboxDist, rasterDist))
			end
			return true
		elseif bboxDist <= 6 then
			closestA = bboxA
			closestB = bboxB
			edgeDist = bboxDist
			if DEBUG_EXTENDED_ADJACENCY then
				print(string.format("[TileAdjacencyManager] AABB override: using bbox edges for %s <-> %s (bbox: %.1f, raster was: %.1f)",
					tileA.Name, tileB.Name, bboxDist, rasterDist))
			end
		end
	end

	-- If the closest edges are too far apart, definitely not walkable
	if edgeDist > 6 then
		if DEBUG_REJECTED_ADJACENCY then
			print(string.format("[TileAdjacencyManager] Rejected: %s <-> %s (edge distance %.1f > 6)",
				tileA.Name, tileB.Name, edgeDist))
		end
		return false
	end

	local rayHeight = math.max(closestA.Y, closestB.Y) + 20
	
	-- DAILY DRIVER FIX: Dynamically calculate ray length to account for cliffs.
	-- A fixed -50 ray will mid-air miss if the cliff is taller than 30 studs.
	local heightDiff = math.abs(closestA.Y - closestB.Y)
	local rayLength = math.max(100, heightDiff + 50) 

	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {EUROPE_MAP}
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.IgnoreWater = true

	-- Check points along the shortest path between closest edges
	-- Use more sample points for better precision
	local numChecks = math.max(5, math.ceil(edgeDist / 0.4))  -- Check every 0.4 studs (denser sampling)
	local groundCount = 0
	local totalChecks = numChecks + 1
	local consecutiveMisses = 0
	local maxConsecutiveMisses = 0
	local groundResults = {}  -- Track which samples had ground

	for i = 0, numChecks do
		local fraction = i / numChecks
		local checkX = closestA.X + (closestB.X - closestA.X) * fraction
		local checkZ = closestA.Z + (closestB.Z - closestA.Z) * fraction
		local origin = Vector3.new(checkX, rayHeight, checkZ)

		-- DAILY DRIVER FIX: Apply the dynamic rayLength here
		local result = Workspace:Raycast(origin, Vector3.new(0, -rayLength, 0), rayParams)

		if result then
			groundCount = groundCount + 1
			consecutiveMisses = 0
			table.insert(groundResults, true)
		else
			consecutiveMisses = consecutiveMisses + 1
			maxConsecutiveMisses = math.max(maxConsecutiveMisses, consecutiveMisses)
			table.insert(groundResults, false)
		end
	end

	-- FIX v9.3: CRITICAL - Check for consecutive misses (water crossing detection)
	-- If we have 2+ consecutive misses, this is a water body, not a small gap
	if maxConsecutiveMisses > MAX_CONSECUTIVE_MISSES then
		if DEBUG_REJECTED_ADJACENCY then
			print(string.format("[TileAdjacencyManager] Rejected (WATER): %s <-> %s (%d consecutive misses, distance: %.1f)",
				tileA.Name, tileB.Name, maxConsecutiveMisses, edgeDist))
		end
		return false
	end

	-- FIX v9.3: CRITICAL - Explicit midpoint check
	-- The middle of the path is most likely to be water
	local midIndex = math.floor(#groundResults / 2) + 1
	if #groundResults >= 3 then
		-- Check that the middle section has ground
		local midStart = math.max(1, midIndex - 1)
		local midEnd = math.min(#groundResults, midIndex + 1)
		local midGroundCount = 0
		for idx = midStart, midEnd do
			if groundResults[idx] then
				midGroundCount = midGroundCount + 1
			end
		end
		-- Require at least 2 of 3 middle points to have ground
		if midGroundCount < 2 then
			if DEBUG_REJECTED_ADJACENCY then
				print(string.format("[TileAdjacencyManager] Rejected (MID-WATER): %s <-> %s (only %d/3 middle points have ground)",
					tileA.Name, tileB.Name, midGroundCount))
			end
			return false
		end
	end

	-- FIX v9.3: Higher ground ratio threshold (85%)
	local groundRatio = groundCount / totalChecks
	local isWalkable = groundRatio >= GROUND_RATIO_THRESHOLD

	if DEBUG_REJECTED_ADJACENCY and not isWalkable then
		print(string.format("[TileAdjacencyManager] Rejected (RATIO): %s <-> %s (ground ratio: %.0f%% < %.0f%%, distance: %.1f)",
			tileA.Name, tileB.Name, groundRatio * 100, GROUND_RATIO_THRESHOLD * 100, edgeDist))
	end

	if DEBUG_EXTENDED_ADJACENCY and isWalkable then
		print(string.format("[TileAdjacencyManager] Accepted: %s <-> %s (ground ratio: %.0f%%, distance: %.1f)",
			tileA.Name, tileB.Name, groundRatio * 100, edgeDist))
	end

	return isWalkable
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
local function hasInterveningTileBetween(tileA, tileB, cellToTilesLookup)
	local ptA, ptB, edgeDist = findClosestEdgePoints(tileA, tileB)
	if not ptA or not ptB or edgeDist <= 0.5 then
		return false
	end
	
	-- Count how many sample points find intervening tiles
	local interveningCount = 0
	local totalSamples = 0
	
	-- Sample along the path at multiple points
	for _, frac in ipairs({0.2, 0.4, 0.6, 0.8}) do
		local sampleX = ptA.X + (ptB.X - ptA.X) * frac
		local sampleZ = ptA.Z + (ptB.Z - ptA.Z) * frac
		local sCx = math.floor(sampleX / RASTER_CELL_SIZE)
		local sCz = math.floor(sampleZ / RASTER_CELL_SIZE)
		local sKey = cellKey(sCx, sCz)
		local tilesAtSample = cellToTilesLookup[sKey]
		totalSamples = totalSamples + 1
		
		if tilesAtSample then
			for _, sTile in ipairs(tilesAtSample) do
				if sTile ~= tileA and sTile ~= tileB then
					interveningCount = interveningCount + 1
					break -- Count each sample point only once
				end
			end
		end
	end
	
	-- Only reject if majority of samples find intervening tiles (more than 50%)
	-- This allows tiles with minor overlaps to still be adjacent
	return interveningCount > (totalSamples / 2)
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

	-- Only reject if majority of samples find intervening tiles (more than 50%)
	return interveningCount > (totalSamples / 2)
end

local function calculateAdjacenciesFromFootprints()
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
	local rejectedByDistance = 0  -- FIX v9.5: Track rejections

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

								-- FIX v9.5: Validate actual edge distance before marking as adjacent
								-- This prevents false adjacencies where cells are grid neighbors
								-- but the tiles are physically far apart
								-- Use findClosestEdgePoints for accurate measurement (AABB can give false positives)
								local _ptA, _ptB, edgeDist = findClosestEdgePoints(tileA, tileB)
								if edgeDist <= MAX_RASTER_ADJACENCY_DISTANCE then
									-- FIX v11/v12: Check for intervening tiles between candidates.
									local hasInterveningTile = hasInterveningTileBetween(tileA, tileB, CellToTilesLocal)
									if hasInterveningTile and DEBUG_REJECTED_ADJACENCY then
										print(string.format("[TileAdjacencyManager] Rejected raster adjacency (intervening tile): %s <-> %s (edge distance %.1f)",
											tileA.Name, tileB.Name, edgeDist))
									end
									if not hasInterveningTile then
										table.insert(AdjacentTiles[tileA], tileB)
										if not AdjacentTiles[tileB] then AdjacentTiles[tileB] = {} end
										table.insert(AdjacentTiles[tileB], tileA)
									else
										rejectedByDistance = rejectedByDistance + 1
									end
								else
									rejectedByDistance = rejectedByDistance + 1
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
	print(string.format("[TileAdjacencyManager] Rasterization adjacency complete: %d connections, avg %.1f per tile (rejected %d by distance)",
		totalConnections, avgConnections, rejectedByDistance))
end

-- FIX v9.3: Extended adjacencies with stricter water detection
local function calculateExtendedAdjacencies()
	if EXTENDED_ADJACENCY_THRESHOLD <= 0 then
		print("[TileAdjacencyManager] Extended adjacency disabled (threshold <= 0)")
		return
	end

	local extendedCount = 0
	local rejectedCount = 0
	--[[
	local rejectedReasons = {
		water = 0,
		midwater = 0,
		ratio = 0,
		distance = 0
	}
	]]

	-- Build quick lookup of existing adjacencies
	local existingAdjacent = {}
	for tileA, neighbors in pairs(AdjacentTiles) do
		existingAdjacent[tileA] = existingAdjacent[tileA] or {}
		for _, tileB in ipairs(neighbors) do
			existingAdjacent[tileA][tileB] = true
		end
	end

	-- FIX v9.6: Precompute max possible adjacency distance for quick filtering
	-- Tiles can only be adjacent if their centers are within this distance
	-- (sum of half-diagonals + threshold)
	local MAX_CENTER_DISTANCE_FOR_ADJACENCY = 100  -- studs - skip pairs further than this

	-- Check all tile pairs for extended adjacency (tiles with small gaps)
	for i = 1, #AllTilesList do
		local tileA = AllTilesList[i]

		for j = i + 1, #AllTilesList do
			local tileB = AllTilesList[j]

			-- Skip if already adjacent (from rasterization)
			if existingAdjacent[tileA] and existingAdjacent[tileA][tileB] then
				continue
			end

			-- FIX v9.6: Quick center-to-center distance check to skip obviously distant tiles
			local centerDistXZ = ((tileA.Position - tileB.Position) * Vector3.new(1, 0, 1)).Magnitude
			local maxPossibleProximity = (tileA.Size.Magnitude + tileB.Size.Magnitude) / 2 + math.max(EXTENDED_ADJACENCY_THRESHOLD, AABB_ADJACENCY_RESCUE_THRESHOLD)
			if centerDistXZ > math.min(MAX_CENTER_DISTANCE_FOR_ADJACENCY, maxPossibleProximity) then
				continue
			end

			-- FIX v12: Two-path adjacency check using both raster and AABB distances
			local _, _, rasterEdgeDistance = findClosestEdgePoints(tileA, tileB)
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
				if isPathWalkable(tileA, tileB) then
					shouldConnect = true
				else
					rejectedCount = rejectedCount + 1
				end
			-- Path B: AABB rescue for short-border tiles missed by rasterization
			-- Tiles are geometrically touching/close but raster cells didn't align at border
			-- FIX v12.1: Now requires BOTH walkability AND no intervening tile
			-- Walkability alone is insufficient: land tiles separated by other tiles pass raycasts
			-- (ground exists everywhere) but should NOT be adjacent because another tile is between them.
			elseif aabbEdgeDistance <= AABB_ADJACENCY_RESCUE_THRESHOLD then
				-- Step 1: Check for intervening tiles (another tile sits between them)
				-- Use BBOX version since raster edge points may be inaccurate for short-border tiles
				local hasIntervening = hasInterveningTileBetweenBBox(tileA, tileB, CellToTilesMap)
				if DEBUG_PAIR then
					warn(string.format("[DEBUG PAIR]   Path B: BBox intervening = %s", tostring(hasIntervening)))
				end
				-- Also check raster-based version as a second opinion
				if not hasIntervening then
					hasIntervening = hasInterveningTileBetween(tileA, tileB, CellToTilesMap)
					if DEBUG_PAIR then
						warn(string.format("[DEBUG PAIR]   Path B: raster intervening (2nd opinion) = %s", tostring(hasIntervening)))
					end
				end

				if hasIntervening then
					rejectedCount = rejectedCount + 1
					if DEBUG_REJECTED_ADJACENCY then
						print(string.format("[TileAdjacencyManager] AABB rescue rejected (intervening tile): %s <-> %s (AABB: %.1f, raster: %.1f)",
								tileA.Name, tileB.Name, aabbEdgeDistance, rasterEdgeDistance))
					end
				-- Step 2: Check walkability (raycasting for water/void)
				elseif isPathWalkable(tileA, tileB, true) then
					shouldConnect = true
					if DEBUG_EXTENDED_ADJACENCY then
						print(string.format("[TileAdjacencyManager] AABB rescue adjacency: %s <-> %s (AABB: %.1f, raster: %.1f)",
								tileA.Name, tileB.Name, aabbEdgeDistance, rasterEdgeDistance))
					end
				else
					rejectedCount = rejectedCount + 1
					if DEBUG_REJECTED_ADJACENCY then
						print(string.format("[TileAdjacencyManager] AABB rescue rejected (unwalkable): %s <-> %s (AABB: %.1f, raster: %.1f)",
								tileA.Name, tileB.Name, aabbEdgeDistance, rasterEdgeDistance))
					end
				end
			end

			if DEBUG_PAIR then
				warn(string.format("[DEBUG PAIR]   Final result: shouldConnect = %s", tostring(shouldConnect)))
			end

			if shouldConnect then
				-- Add bidirectional adjacency
				if not AdjacentTiles[tileA] then AdjacentTiles[tileA] = {} end
				if not AdjacentTiles[tileB] then AdjacentTiles[tileB] = {} end

				table.insert(AdjacentTiles[tileA], tileB)
				table.insert(AdjacentTiles[tileB], tileA)

				-- Update lookup
				existingAdjacent[tileA] = existingAdjacent[tileA] or {}
				existingAdjacent[tileB] = existingAdjacent[tileB] or {}
				existingAdjacent[tileA][tileB] = true
				existingAdjacent[tileB][tileA] = true

				extendedCount = extendedCount + 1

				if DEBUG_EXTENDED_ADJACENCY then
					print(string.format("[TileAdjacencyManager] Extended adjacency: %s <-> %s (raster: %.1f, AABB: %.1f)",
						tileA.Name, tileB.Name, rasterEdgeDistance, aabbEdgeDistance))
				end
			end
		end

		-- Yield occasionally to prevent timeout
		if i % 50 == 0 then
			task.wait(0)
		end
	end

	print(string.format("[TileAdjacencyManager] Extended adjacency: added %d connections (gap + AABB rescue), rejected %d (water/void/intervening)",
		extendedCount, rejectedCount))
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
	PositionToTile = {}
	AllTilesList = {}

	for _, countryModel in ipairs(EUROPE_MAP:GetChildren()) do
		if countryModel:IsA("Model") then
			TileParts[countryModel.Name] = {}

			for _, part in ipairs(countryModel:GetDescendants()) do
				if part:IsA("BasePart") then
					table.insert(TileParts[countryModel.Name], part)
					table.insert(AllTilesList, part)

					local lookupPos = part.Position + Vector3.new(0, part.Size.Y / 2 + 3, 0)
					local key = getTileKey(lookupPos)
					if PositionToTile[key] and PositionToTile[key] ~= part then
						warn("[TileAdjacencyManager] Key collision! Key: " .. key ..
							" already maps to " .. PositionToTile[key]:GetFullName() ..
							", overwriting with " .. part:GetFullName())
					end
					PositionToTile[key] = part
				end
			end
		end
	end

	print(string.format("[TileAdjacencyManager] Scanned %d tiles across %d countries",
		#AllTilesList, #EUROPE_MAP:GetChildren()))
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
	return PositionToTile[getTileKey(position)]
end

function TileAdjacencyManager.getTileFromKey(tileKey)
	return PositionToTile[tileKey]
end

function TileAdjacencyManager.getTileFromKeyWithFallback(tileKey)
	local tile = PositionToTile[tileKey]
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
	local _, _, rasterEdgeDist = findClosestEdgePoints(tileA, tileB)
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
		if hasIntervening then
			warn("  ❌ BLOCKED at raster stage by intervening tile check")
		elseif rasterEdgeDist > MAX_RASTER_ADJACENCY_DISTANCE then
			warn(string.format("  ❌ BLOCKED at raster stage: edge distance %.2f > MAX_RASTER_ADJACENCY_DISTANCE %d", rasterEdgeDist, MAX_RASTER_ADJACENCY_DISTANCE))
		else
			warn("  ⚠️ Unknown reason for raster stage rejection despite sharing grid neighbors")
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
				local walkable = isPathWalkable(tileA, tileB, true)
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
	local keyA = npcA:GetAttribute("TileKey")
	local keyB = npcB:GetAttribute("TileKey")

	if not keyA or not keyB then return false end
	if keyA == keyB then return true end

	local tileA = PositionToTile[keyA] or TileAdjacencyManager.getTileFromKeyWithFallback(keyA)
	local tileB = PositionToTile[keyB] or TileAdjacencyManager.getTileFromKeyWithFallback(keyB)

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

	local tileA = PositionToTile[tileKeyA]
	local tileB = PositionToTile[tileKeyB]

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

function TileAdjacencyManager.recalculate()
	rasterizeAllTiles()
	calculateAdjacenciesFromFootprints()
	calculateExtendedAdjacencies()
	calculateSafeCenters()
end

-- FIX v17: Export isPathWalkable for use in NPCMovementSystem after edge point correction
-- Now accepts optional pre-computed edge points to avoid redundant findClosestEdgePoints() calls
function TileAdjacencyManager.isPathWalkable(tileA, tileB, pointA, pointB)
	if pointA and pointB then
		-- Use provided edge points, validate walkability directly
		local closestA, closestB = pointA, pointB
		local edgeDist = math.sqrt((pointA.X - pointB.X)^2 + (pointA.Z - pointB.Z)^2)

		-- FIX v9.4: Close tiles bypass water checks
		if edgeDist <= EXTENDED_ADJACENCY_THRESHOLD then
			return true
		end

		-- If edges are too far apart, not walkable
		if edgeDist > 6 then
			return false
		end

		local rayHeight = math.max(closestA.Y, closestB.Y) + 20

		local rayParams = RaycastParams.new()
		rayParams.FilterDescendantsInstances = {EUROPE_MAP}
		rayParams.FilterType = Enum.RaycastFilterType.Include
		rayParams.IgnoreWater = true

		-- Dense sampling: every 0.4 studs along the edge path
		local numChecks = math.max(5, math.ceil(edgeDist / 0.4))
		local groundCount = 0
		local totalChecks = numChecks + 1
		local consecutiveMisses = 0
		local maxConsecutiveMisses = 0
		local groundResults = {}

		for i = 0, numChecks do
			local fraction = i / numChecks
			local checkX = closestA.X + (closestB.X - closestA.X) * fraction
			local checkZ = closestA.Z + (closestB.Z - closestA.Z) * fraction
			local origin = Vector3.new(checkX, rayHeight, checkZ)

			local result = Workspace:Raycast(origin, Vector3.new(0, -50, 0), rayParams)

			if result then
				groundCount = groundCount + 1
				consecutiveMisses = 0
				table.insert(groundResults, true)
			else
				consecutiveMisses = consecutiveMisses + 1
				maxConsecutiveMisses = math.max(maxConsecutiveMisses, consecutiveMisses)
				table.insert(groundResults, false)
			end
		end

		-- Check for consecutive misses (water crossing detection)
		if maxConsecutiveMisses > MAX_CONSECUTIVE_MISSES then
			return false
		end

		-- Explicit midpoint check
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
			-- Require at least 2 of 3 middle points to have ground
			if midGroundCount < 2 then
				return false
			end
		end

		-- 85% ground ratio threshold
		local groundRatio = groundCount / totalChecks
		return groundRatio >= GROUND_RATIO_THRESHOLD
	else
		-- No pre-computed points - call local isPathWalkable normally
		return isPathWalkable(tileA, tileB, false)
	end
end

---------------------------------------------------
-- Init
---------------------------------------------------

scanAllTiles()
rasterizeAllTiles()
calculateAdjacenciesFromFootprints()
calculateExtendedAdjacencies()
calculateSafeCenters()

return TileAdjacencyManager
