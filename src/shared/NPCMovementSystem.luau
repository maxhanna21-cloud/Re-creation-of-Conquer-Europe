-- NPCMovementSystem (ModuleScript in ServerScriptService) - PATCHED v3
-- Backwards-compatible with your original API
-- Added: teleport throttle, stuck detection + retry/backoff, OnOwnerChanged, safe-center validation
-- FIX v7: Edge detection during movement (hasGroundAhead) + path corridor correction to prevent map fall-off
-- FIX v8: Pathfinding now validates intermediate tiles for diplomacy and occupation
--         NPCs cannot path through enemy territory without war declared
--         NPCs cannot path through tiles occupied by other NPCs

local RunService = game:GetService("RunService")
-- local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")

local NPCMovementSystem = {}

-- Lazy-load dependencies to avoid circular requires
local TileManager = nil
local TileAdjacencyManager = nil
local TileOwnershipManager = nil
local DiplomacyManager = nil
local Combat = nil
local ServerState = nil

local function getDependencies()
	if not TileManager then
		TileManager = require(game.ServerScriptService:WaitForChild("TileManager", 10))
	end
	if not TileAdjacencyManager then
		TileAdjacencyManager = require(game.ServerScriptService:WaitForChild("TileAdjacencyManager", 10))
	end
	if not TileOwnershipManager then
		TileOwnershipManager = require(game.ServerScriptService:WaitForChild("TileOwnershipManager", 10))
	end
	if not DiplomacyManager then
		DiplomacyManager = require(game.ServerScriptService:WaitForChild("DiplomacyManager", 10))
	end
	if not Combat then
		Combat = require(game.ServerScriptService:WaitForChild("NPCCombatSystem", 10))
	end
	if not ServerState then
		ServerState = require(game.ServerScriptService:WaitForChild("ServerState", 10))
	end
end

-- Configuration
local DEBUG = true
local ARRIVAL_THRESHOLD = 3      -- How close NPC must be to destination (XZ)
local GROUND_CHECK_INTERVAL = 0.1 -- How often to check if NPC is on valid ground (faster = catches falls sooner)
local MAP_MIN_Y = -500 -- INCREASED: Ensure this is lower than your lowest province
local FALL_Y_THRESHOLD = -5      -- If NPC's Y velocity is below this, they are falling
local IDLE_DRIFT_THRESHOLD = 2   -- FIX v6: Max studs an idle NPC can drift from tile center before being snapped back

-- New configs
local TELEPORT_MIN_INTERVAL = 1.0   -- seconds between teleports for same NPC
local STUCK_CHECK_TIME = 1.0        -- seconds sampling window for stuck detection
local STUCK_DISTANCE_THRESHOLD = 0.8 -- studs moved within STUCK_CHECK_TIME considered stuck
local MAX_MOVE_RETRIES = 3
local MOVE_RETRY_BACKOFF = 0.25     -- seconds * attemptNumber
local SAFE_CENTER_GROUND_TOLERANCE = 100 -- INCREASED: Allows NPCs to "see" the floor of deep cliffs
-- local MOVEMENT_EDGE_CHECK_DISTANCE = 3   -- studs ahead to check for ground during movement
local MOVEMENT_PATH_DRIFT_MAX = 5        -- max studs NPC can drift from origin-to-target line before correction
local EDGE_ARRIVAL_THRESHOLD = 2         -- tighter arrival threshold for edge-crossing waypoints (studs)
local MAX_FALL_RECOVERIES = 3            -- FIX v9: max consecutive fall recoveries before aborting movement
local FALL_RECOVERY_RESET_TIME = 5.0     -- FIX v9: seconds of no falls before counter resets

-- Movement state tracking
-- movementStates[npcModel] = { state = "Idle"/"Moving"/"Retreating", lastTeleport = number, stuckSince = number, lastSamplePos = Vector3, lastSampleTime = number, moveAttempts = int }
local movementStates = {}
local activeMovements = {} -- activeMovements[npcModel] = { targetTileKey, originTileKey, targetPosition, originPosition, connection }
local reservedTiles = {}   -- reservedTiles[tileKey] = npcModel

-- Ground check tracking
local groundCheckConnections = {}

---------------------------------------------------
-- Helper Functions (unchanged semantics, extended)
---------------------------------------------------

local function getRootPart(model)
	if not model then return nil end
	return model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Torso") or model.PrimaryPart
end

local function getHumanoid(model)
	if not model then return nil end
	return model:FindFirstChildOfClass("Humanoid")
end

local function getTileSpawnPosition(tilePart)
	if not tilePart then return nil end
	getDependencies()
	local safeCenter = TileAdjacencyManager.getSafeCenter(tilePart)
	if safeCenter then
		return safeCenter
	end
	return tilePart.Position + Vector3.new(0, tilePart.Size.Y / 2 + 3, 0)
end

-- Minimal debug marker (auto-cleans after life)
local function makeDebugPart(name, pos, size, color, life)
	if not DEBUG then return end
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.Size = size or Vector3.new(0.5,0.5,0.5)
	p.CFrame = CFrame.new(pos)
	p.Material = Enum.Material.Neon
	p.Color = color or Color3.fromRGB(255,255,0)
	p.Parent = Workspace
	if life and life > 0 then
		task.delay(life, function()
			if p and p.Parent then p:Destroy() end
		end)
	end
	return p
end

---------------------------------------------------
-- FIX v4: Ground/Boundary Validation (extended)
---------------------------------------------------

local function isOnValidGround(npcModel)
	getDependencies()

	local root = getRootPart(npcModel)
	if not root then return false end

	-- DAILY DRIVER FIX: Ensure NPC hasn't hit the absolute map floor
	if root.Position.Y < MAP_MIN_Y then
		if DEBUG then
			warn("[NPCMovement:GroundCheck] " .. npcModel.Name .. " FELL below MAP_MIN_Y (" .. MAP_MIN_Y .. ")")
		end
		return false
	end

	-- Check if NPC is actually falling (significant downward velocity)
	local velocity = root.AssemblyLinearVelocity
	local isFalling = velocity and velocity.Y < FALL_Y_THRESHOLD

	-- If not falling (stationary or moving horizontally), assume they are safe
	if not isFalling then
		return true
	end

	-- NPC is falling - check if there's ground below to catch them
	local europeMap = Workspace:FindFirstChild("EuropeMap")
	if not europeMap then return false end

	-- DAILY DRIVER FIX: Use a dynamic ray length based on the distance to the map floor.
	-- This prevents NPCs from "dying" mid-air while falling down a legal cliff.
	local rayOrigin = root.Position + Vector3.new(0, 2, 0)
	local distanceToFloor = math.abs(root.Position.Y - MAP_MIN_Y)
	local rayDirection = Vector3.new(0, -distanceToFloor, 0)

	local params = RaycastParams.new()
	params.FilterDescendantsInstances = {europeMap}
	params.FilterType = Enum.RaycastFilterType.Include
	params.IgnoreWater = true

	local result = Workspace:Raycast(rayOrigin, rayDirection, params)

	if result then
		-- There's a tile below - the NPC is falling safely toward a destination
		return true
	end

	-- NPC is falling AND there's no tile below (checked all the way to MAP_MIN_Y)
	-- BUT check for gap-crossing waypoints before declaring emergency
	local mState = movementStates[npcModel]
	local movement = activeMovements[npcModel]
	if mState and mState.state == "Moving" and movement and movement.enrichedWaypoints then
		local wpIdx = movement.currentWaypoint or 1
		for checkIdx = math.max(1, wpIdx - 1), math.min(#movement.enrichedWaypoints, wpIdx + 1) do
			local wp = movement.enrichedWaypoints[checkIdx]
			if wp and wp.type == "edge" then
				local distToEdge = ((root.Position - wp.position) * Vector3.new(1, 0, 1)).Magnitude
				if distToEdge < 5 then
					return true -- Near edge waypoint, trust the system to catch them
				end
			end
		end
	end

	return false -- True fall into the void
end

-- Check if there's valid ground AHEAD of the NPC in their movement direction
-- Uses whitelist raycast to only detect actual EuropeMap tiles, not water/void
-- Only checks when NPC has moved significantly from origin (to avoid false positives at tile boundaries)
--[[
local function hasGroundAhead(npcModel, targetPos, originPos)
	getDependencies()

	local root = getRootPart(npcModel)
	if not root then return true end -- assume safe if we can't check

	local currentPos = root.Position

	-- FIX: Reduced detection dead zones - was 5 studs from origin, now 2 studs
	-- This was causing NPCs to have 5 full studs of unguarded movement at the start
	if originPos then
		local distFromOrigin = ((currentPos - originPos) * Vector3.new(1, 0, 1)).Magnitude
		if distFromOrigin < 2 then
			return true -- Still very close to origin, don't trigger edge detection yet
		end
	end

	-- FIX: Reduced near-target dead zone from 3 studs to 1 stud
	-- Allows approach movement but catches NPCs that lose ground mid-approach
	local distToTarget = ((currentPos - targetPos) * Vector3.new(1, 0, 1)).Magnitude
	if distToTarget < 1 then
		return true -- Very close to target, let arrival logic handle final step
	end

	local directionXZ = (targetPos - currentPos) * Vector3.new(1, 0, 1)
	if directionXZ.Magnitude < 0.1 then return true end -- close enough, don't check

	-- Get EuropeMap for whitelist raycast
	local europeMap = Workspace:FindFirstChild("EuropeMap")
	if not europeMap then return true end -- can't check without map reference

	local params = RaycastParams.new()
	params.FilterDescendantsInstances = {europeMap}
	params.FilterType = Enum.RaycastFilterType.Include
	params.IgnoreWater = true

	-- Only check at current position (are we still on a tile?)
	-- This is more reliable than checking ahead which can hit gaps between tiles
	local rayOrigin = Vector3.new(currentPos.X, currentPos.Y + 10, currentPos.Z)
	local rayDirection = Vector3.new(0, -25, 0)

	local result = Workspace:Raycast(rayOrigin, rayDirection, params)

	if not result then
		-- Not currently over any EuropeMap tile
		if DEBUG then
			print("[NPCMovement] NPC " .. npcModel.Name .. " is not over any tile!")
		end
		return false
	end

	-- Verify we're on top of a tile, not on its side
	if result.Normal.Y < 0.3 then
		if DEBUG then
			print("[NPCMovement] NPC " .. npcModel.Name .. " is on tile side, not stable")
		end
		return false
	end

	return true
end
]]

-- FIX: Smart path validation - only blocks truly impassable paths
-- Checks origin, target, and midpoint. Allows humanoid controller to handle minor gaps
--[[
local function isPathTraversable(originPos, targetPos)
	getDependencies()

	local europeMap = Workspace:FindFirstChild("EuropeMap")
	if not europeMap then return true end -- Can't validate, assume OK

	local params = RaycastParams.new()
	params.FilterDescendantsInstances = {europeMap}
	params.FilterType = Enum.RaycastFilterType.Include
	params.IgnoreWater = true

	local pathDirection = targetPos - originPos
	local pathDistance = pathDirection.Magnitude

	if pathDistance < 0.1 then return true end -- Same position, OK

	-- Only check 3 critical points: start, middle, end
	-- This avoids blocking legitimate movement while catching major gaps
	local checkPositions = {
		originPos,           -- Start point
		originPos:Lerp(targetPos, 0.5),  -- Midpoint
		targetPos            -- End point
	}

	local groundCount = 0
	for _, checkPos in ipairs(checkPositions) do
		-- Raycast down from this point
		local rayOrigin = checkPos + Vector3.new(0, 5, 0)
		local rayDir = Vector3.new(0, -20, 0)

		local result = Workspace:Raycast(rayOrigin, rayDir, params)

		if result then
			-- Found ground at this point
			groundCount = groundCount + 1
		end
	end

	-- Require at least 2 of 3 points to have ground
	-- This allows the humanoid controller to handle single gaps
	-- But blocks paths where most/all points lack ground
	if groundCount < 2 then
		if DEBUG then
			print("[NPCMovement:PathValidation] Path validation FAILED - only " .. groundCount .. "/3 points have ground")
		end
		return false
	end

	return true -- Path is traversable
end
]]

-- FIX v8: Helper function to check if NPC can PASS THROUGH a tile (not capture, just traverse)
-- This is more lenient than canMoveToTile since we allow passage through allied territory
local function canPassThroughTile(owner, role, tilePart, playerCountry)
	getDependencies()

	if not tilePart then return false end

	local tileCountry = TileAdjacencyManager.getTileCountry(tilePart)
	local tileKey = TileManager.getTileKeyFromPart(tilePart)

	-- Check tile occupation first - cannot pass through ANY occupied tiles
	if tileKey then
		local occupant = TileManager.getTileOccupant(tileKey)
		if occupant then
			return false -- Tile is occupied, block pathfinding through it
		end
	end

	-- Own territory - always allowed
	if tileCountry == playerCountry then
		return true
	end

	-- Already occupied by us (captured territory) - always allowed
	if TileOwnershipManager.isOccupiedBy(tilePart, owner) then
		return true
	end

	-- Different country
	if tileCountry and tileCountry ~= playerCountry then
		local CountryOwners = ServerState.getCountryOwners()
		local tileOwner = CountryOwners[tileCountry]

		-- Conquered territory check (by us)
		if type(tileOwner) == "string" and tileOwner:find("Conquered_") then
			local conquerorCountry = tileOwner:gsub("Conquered_", "")
			if conquerorCountry == playerCountry then
				return true
			end
			-- FIX v9: Handle conquered territory owned by someone else
			-- Check if allied with the conqueror
			if DiplomacyManager.areCountriesAllied(playerCountry, conquerorCountry) then
				return true
			end
			-- Defenders cannot pass through enemy-conquered territory
			if role == "Defender" then
				return false
			end
			-- Attackers need war with the conqueror to pass
			if not DiplomacyManager.areCountriesAtWar(playerCountry, conquerorCountry) then
				return false
			end
			return true
		end

		-- Allied territory - allow passage (FIX v8: allies can pass through each other's territory)
		if typeof(tileOwner) == "Instance" and tileOwner:IsA("Player") then
			if DiplomacyManager.areAllied(owner, tileOwner) then
				return true
			end
		end

		-- Defenders cannot pass through enemy territory
		if role == "Defender" then
			return false
		end

		-- For attackers: need to be at war to pass through enemy territory
		if typeof(tileOwner) == "Instance" and tileOwner:IsA("Player") then
			if not DiplomacyManager.areAtWar(owner, tileOwner) then
				return false
			end
			return true
		elseif tileOwner == "Unowned" then
			-- Cannot pass through neutral territory
			return false
		end
	end

	return true
end

-- FIX v8: Smart pathfinding through adjacent tiles WITH diplomacy validation
-- Finds a safe route from source to destination using the adjacency graph
-- Returns: list of tile parts to visit in order (shortest path)
-- Now validates each intermediate tile for diplomacy and occupation
local function findTilePath(sourceTilePart, destinationTilePart, maxDepth, owner, role, playerCountry)
	if not sourceTilePart or not destinationTilePart then return nil end
	if sourceTilePart == destinationTilePart then return {sourceTilePart} end

	getDependencies()

	maxDepth = maxDepth or 20  -- Prevent infinite loops on large maps

	-- Breadth-first search through adjacent tiles
	local queue = {{sourceTilePart, {sourceTilePart}}}  -- {current tile, path taken}
	local visited = {[sourceTilePart] = true}

	while #queue > 0 do
		local current, path = queue[1][1], queue[1][2]
		table.remove(queue, 1)

		-- If we've reached the destination, return the path
		if current == destinationTilePart then
			return path
		end

		-- Prevent paths that are too long (probably stuck in a loop)
		if #path < maxDepth then
			-- Get adjacent tiles
			local neighbors = TileAdjacencyManager.getAdjacentTiles(current)
			if neighbors and #neighbors > 0 then
				for _, neighbor in ipairs(neighbors) do
					if not visited[neighbor] then
						-- FIX v8: Validate if we can pass through this tile
						-- For intermediate tiles, check passage rules
						-- For the final destination, we use the stricter canMoveToTile check later
						local isDestination = (neighbor == destinationTilePart)
						local canPass = true

						if owner and role and playerCountry then
							if isDestination then
								-- Final destination - will be validated by canMoveToTile later
								-- Just do a basic passage check here
								canPass = canPassThroughTile(owner, role, neighbor, playerCountry)
							else
								-- Intermediate tile - must be passable
								canPass = canPassThroughTile(owner, role, neighbor, playerCountry)
							end
						end

						if canPass then
							visited[neighbor] = true
							local newPath = {}
							for _, tile in ipairs(path) do
								table.insert(newPath, tile)
							end
							table.insert(newPath, neighbor)
							table.insert(queue, {neighbor, newPath})

							-- Early exit if we found the destination
							if neighbor == destinationTilePart then
								return newPath
							end
						else
							-- Mark as visited to avoid rechecking, but don't add to queue
							visited[neighbor] = true
							if DEBUG then
								print("[NPCMovement:Pathfinding] Cannot pass through " .. neighbor.Name .. " (diplomacy/occupation blocked)")
							end
						end
					end
				end
			end
		end
	end

	-- No path found
	return nil
end

-- Calculate distance from a point to a line segment (for path drift detection)
local function pointToLineDistance(point, lineStart, lineEnd)
	local lineVec = lineEnd - lineStart
	local pointVec = point - lineStart
	local lineLenSq = lineVec.Magnitude ^ 2

	if lineLenSq < 0.001 then
		return pointVec.Magnitude
	end

	-- Project point onto line, clamped to segment
	local t = math.clamp(lineVec:Dot(pointVec) / lineLenSq, 0, 1)
	local projection = lineStart + lineVec * t
	return (point - projection).Magnitude
end

-- Get a corrected movement target that keeps NPC on a safe path corridor
local function getPathCorrectedPosition(npcModel, originPos, targetPos)
	local root = getRootPart(npcModel)
	if not root then return targetPos end

	local currentPosXZ = root.Position * Vector3.new(1, 0, 1)
	local originPosXZ = originPos * Vector3.new(1, 0, 1)
	local targetPosXZ = targetPos * Vector3.new(1, 0, 1)

	-- Calculate drift from the ideal path (line from origin to target)
	local driftDist = pointToLineDistance(currentPosXZ, originPosXZ, targetPosXZ)

	if driftDist > MOVEMENT_PATH_DRIFT_MAX then
		-- NPC has drifted too far - calculate a corrected target
		-- Find the closest point on the ideal path
		local lineVec = targetPosXZ - originPosXZ
		local pointVec = currentPosXZ - originPosXZ
		local lineLenSq = lineVec.Magnitude ^ 2
		local t = 0.5
		if lineLenSq > 0.001 then
			t = math.clamp(lineVec:Dot(pointVec) / lineLenSq, 0, 1)
		end
		local closestOnPath = originPosXZ + lineVec * t

		-- Blend toward the path: move toward a point that's between the path and the target
		local correctionStrength = 0.7 -- how strongly to pull back to path
		local correctedXZ = currentPosXZ:Lerp(closestOnPath, correctionStrength)

		-- Use the target's Y position
		return Vector3.new(correctedXZ.X, targetPos.Y, correctedXZ.Z)
	end

	return targetPos
end

-- Compute a walkable path between two positions using PathfindingService.
-- Returns an array of Vector3 intermediate waypoints (excluding start/end), or empty table if direct path is ok.
local function computeWalkablePath(startPos, endPos)
	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = false,
		WaypointSpacing = 4,
	})

	local success, err = pcall(function()
		path:ComputeAsync(startPos, endPos)
	end)

	if not success or path.Status ~= Enum.PathStatus.Success then
		if DEBUG then
			print(string.format("[NPCMovement:Pathfind] PathfindingService failed from (%.1f,%.1f,%.1f) to (%.1f,%.1f,%.1f): %s",
				startPos.X, startPos.Y, startPos.Z, endPos.X, endPos.Y, endPos.Z,
				err or tostring(path.Status)))
		end
		return {}
	end

	local pfWaypoints = path:GetWaypoints()
	local intermediates = {}

	-- Skip first (start) and last (end) waypoints — we already have those
	for wpIdx = 2, #pfWaypoints - 1 do
		table.insert(intermediates, pfWaypoints[wpIdx].Position)
	end

	return intermediates
end

-- Build enriched waypoints that inject edge-crossing points for gap-connected tiles.
-- For narrow/curved tiles, uses PathfindingService to navigate from safe center to edge.
local function buildEnrichedWaypoints(tilePath)
	getDependencies()
	if not tilePath or #tilePath < 2 then return nil end

	local waypoints = {}

	-- First waypoint: current tile (will be skipped via currentWaypoint = 2)
	table.insert(waypoints, {
		type = "tile",
		tile = tilePath[1],
		position = getTileSpawnPosition(tilePath[1])
	})

	for i = 2, #tilePath do
		local prevTile = tilePath[i - 1]
		local currTile = tilePath[i]

		-- Check if this pair has a gap between edges
		local pointA, pointB, edgeDist = TileAdjacencyManager.findClosestEdgePoints(prevTile, currTile)

		-- FIX v10: Validate edge points have walkable surface on their respective tiles
		-- Bounding box edge sampling can return points off-tile for irregular/rotated tiles
		if pointA and pointB then
			local correctedA = TileAdjacencyManager.findNearestSurfacePoint(prevTile, pointA)
			local correctedB = TileAdjacencyManager.findNearestSurfacePoint(currTile, pointB)
			if correctedA then
				pointA = correctedA
			end
			if correctedB then
				pointB = correctedB
			end
			-- Recalculate edge distance after correction
			if correctedA or correctedB then
				local dx = pointA.X - pointB.X
				local dz = pointA.Z - pointB.Z
				edgeDist = math.sqrt(dx * dx + dz * dz)
			end
		end


	-- FIX v17: Validate the path between corrected edge points using TileAdjacencyManager's robust walkability check
	-- This reuses the battle-tested 85% ground ratio, consecutive barrier detection, and adaptive tolerance logic
	if pointA and pointB then
		local isWalkable = TileAdjacencyManager.isPathWalkable(prevTile, currTile, pointA, pointB)
		if not isWalkable then
			if DEBUG then
				warn(string.format("[NPCMovement:Waypoints] Path not walkable after correction: %s -> %s (using center-to-center fallback)",
					prevTile.Name, currTile.Name))
			end
			pointA = nil
			pointB = nil
		end
	end

		if DEBUG then
			print(string.format("[NPCMovement:Waypoints] Edge check: %s -> %s, edgeDist=%.3f, pointA=%s, pointB=%s",
				prevTile.Name, currTile.Name, edgeDist or -1,
				pointA and string.format("(%.1f,%.1f,%.1f)", pointA.X, pointA.Y, pointA.Z) or "nil",
				pointB and string.format("(%.1f,%.1f,%.1f)", pointB.X, pointB.Y, pointB.Z) or "nil"))
		end

		-- FIX v15: Safety check - if edge points are nil, skip gap crossing entirely
		if not pointA or not pointB then
			if DEBUG then
				warn(string.format("[NPCMovement:Waypoints] Edge points are nil for %s -> %s, skipping gap crossing (will use center-to-center)",
					prevTile.Name, currTile.Name))
			end
			-- Fall through to tile center waypoint addition (line ~850)
		end

		-- Gap crossing: edge distance > 0.1 studs (epsilon to ignore floating-point noise on touching tiles)
		local isGapCrossing = pointA and pointB and edgeDist > 0.1

		-- FIX v9: For small gaps (< 3 studs), use simple direct movement instead of PathfindingService
		-- PathfindingService often creates overly complex paths that lead to falls
		local isSmallGap = edgeDist and edgeDist < 3.0

		if isGapCrossing and isSmallGap then
			-- Simple approach for small gaps: just add edge points (tile center added below)
			-- FIX v15: Use corrected Y from surface validation (pointA/pointB already corrected above at lines 556-565)
			-- This preserves actual ground height instead of generic safeCenterA.Y
			local safeCenterA = getTileSpawnPosition(prevTile)
			local safeCenterB = getTileSpawnPosition(currTile)

			local edgePointA = pointA
			local edgePointB = pointB

			if DEBUG then
				print(string.format("[NPCMovement:Waypoints] Small gap (%.1f studs): using direct edge crossing %s -> %s",
					edgeDist, prevTile.Name, currTile.Name))
			end

			-- Edge waypoint on departing tile
			table.insert(waypoints, {
				type = "edge",
				position = edgePointA,
				tile = prevTile
			})

			-- Edge waypoint on arriving tile
			table.insert(waypoints, {
				type = "edge",
				position = edgePointB,
				tile = currTile
			})

			-- Note: tile center waypoint is added below (line ~779)

		elseif isGapCrossing then
			-- FIX v15: Use corrected Y from surface validation (pointA/pointB already corrected above at lines 556-565)
			-- This preserves actual ground height instead of generic safeCenterA.Y
			local safeCenterA = getTileSpawnPosition(prevTile)
			local safeCenterB = getTileSpawnPosition(currTile)

			local edgePointA = pointA
			local edgePointB = pointB

			-- Strategy: Use PathfindingService to find a walkable route from the previous
			-- position to the departure edge point. This handles narrow/curved tiles where
			-- a straight line from center to edge would cross void.
			local prevPos = waypoints[#waypoints].position
			local pfIntermediates = computeWalkablePath(prevPos, edgePointA)

			if #pfIntermediates > 0 then
				-- PathfindingService found a route along the tile surface to the edge
				if DEBUG then
					print(string.format("[NPCMovement:Waypoints] PathfindingService added %d intermediate waypoints to reach edge on %s",
						#pfIntermediates, prevTile.Name))
				end
				for _, pfPos in ipairs(pfIntermediates) do
					table.insert(waypoints, {
						type = "pathfind",
						position = pfPos,  -- FIX v15: Preserve PathfindingService Y (handles slopes/ramps)
						tile = prevTile
					})
				end

				-- Edge waypoint on departing tile
				table.insert(waypoints, {
					type = "edge",
					position = edgePointA,
					tile = prevTile
				})

				-- Edge waypoint on arriving tile
				table.insert(waypoints, {
					type = "edge",
					position = edgePointB,
					tile = currTile
				})
			else
				-- PathfindingService couldn't find a route to the departure edge.
				-- Fallback: try pathfinding directly from current position to the ARRIVAL edge
				-- (crossing the gap via navmesh). This works when the navmesh bridges the gap.
				local pfCrossing = computeWalkablePath(prevPos, edgePointB)

				if #pfCrossing > 0 then
					if DEBUG then
						print(string.format("[NPCMovement:Waypoints] Fallback: PathfindingService found %d waypoints to cross directly to %s",
							#pfCrossing, currTile.Name))
					end
					for _, pfPos in ipairs(pfCrossing) do
						table.insert(waypoints, {
							type = "pathfind",
							position = pfPos,  -- FIX v15: Preserve PathfindingService Y (handles slopes/ramps)
							tile = prevTile
						})
					end

					-- Arrival edge waypoint
					table.insert(waypoints, {
						type = "edge",
						position = edgePointB,
						tile = currTile
					})
				else
					-- Last resort: try pathfinding to the destination safe center directly
					local pfDirect = computeWalkablePath(prevPos, safeCenterB)

					if #pfDirect > 0 then
						if DEBUG then
							print(string.format("[NPCMovement:Waypoints] Last resort: PathfindingService found %d waypoints directly to %s center",
								#pfDirect, currTile.Name))
						end
						for _, pfPos in ipairs(pfDirect) do
							table.insert(waypoints, {
								type = "pathfind",
								position = pfPos,  -- FIX v15: Preserve PathfindingService Y (handles slopes/ramps)
								tile = nil
							})
						end
					else
						-- PathfindingService completely failed (navmesh doesn't cover narrow tiles).
						-- Fallback: use raster cell-based pathfinding through the tile's footprint.
						local cellPath = TileAdjacencyManager.findCellPath(prevTile, prevPos, edgePointA)

						if #cellPath > 0 then
							if DEBUG then
								print(string.format("[NPCMovement:Waypoints] Cell-based fallback found %d waypoints to edge on %s",
									#cellPath, prevTile.Name))
							end
							for _, cellPos in ipairs(cellPath) do
								table.insert(waypoints, {
									type = "pathfind",
									position = cellPos,  -- FIX v15: Preserve cell path Y (from tile surface raycast)
									tile = prevTile
								})
							end

							-- Edge waypoints for the gap crossing
							table.insert(waypoints, {
								type = "edge",
								position = edgePointA,
								tile = prevTile
							})
							table.insert(waypoints, {
								type = "edge",
								position = edgePointB,
								tile = currTile
							})
						else
							-- Cell path to departure edge also failed.
							-- Try cell path from arrival side: find a path on the destination tile
							-- from its edge to its center (we'll reverse the approach).
							local cellPathB = TileAdjacencyManager.findCellPath(prevTile, prevPos, Vector3.new(pointA.X, 0, pointA.Z))

							if #cellPathB > 0 then
								if DEBUG then
									print(string.format("[NPCMovement:Waypoints] Cell fallback (nearest edge) found %d waypoints on %s",
										#cellPathB, prevTile.Name))
								end
								for _, cellPos in ipairs(cellPathB) do
									table.insert(waypoints, {
										type = "pathfind",
										position = cellPos,  -- FIX v15: Preserve cell path Y (from tile surface raycast)
										tile = prevTile
									})
								end
								-- Add edge waypoints
								table.insert(waypoints, {
									type = "edge",
									position = edgePointA,
									tile = prevTile
								})
								table.insert(waypoints, {
									type = "edge",
									position = edgePointB,
									tile = currTile
								})
							else
								-- All pathfinding failed. Skip edge waypoints, fall back to direct
								-- center-to-center movement (old behavior). Log a warning.
								if DEBUG then
									print(string.format("[NPCMovement:Waypoints] WARNING: All pathfinding failed for %s -> %s gap (including cell-based). Using direct movement (may fall).",
										prevTile.Name, currTile.Name))
								end
							end
						end
					end
				end
			end

			if DEBUG then
				print(string.format("[NPCMovement:Waypoints] Gap crossing: %s -> %s (%.1f stud gap)",
					prevTile.Name, currTile.Name, edgeDist))
			end
		end

		-- FIX v11: Arrival-tile pathfinding
		-- After crossing a gap, pathfind from the arrival edge to the tile center.
		-- Straight-line edge->center can cross voids on irregularly-shaped tiles.
		if #waypoints >= 2 then
			local lastWP = waypoints[#waypoints]
			-- Only run arrival pathfinding if last waypoint was an edge on the arrival tile
			if lastWP.type == "edge" and lastWP.tile == currTile then
				local arrivalSafeCenter = getTileSpawnPosition(currTile)

				-- Strategy 1: PathfindingService
				local arrivalPath = computeWalkablePath(lastWP.position, arrivalSafeCenter)

				if #arrivalPath > 0 then
					if DEBUG then
						print(string.format(
							"[NPCMovement:Waypoints] Arrival pathfinding: %d intermediates on %s (edge -> center)",
							#arrivalPath, currTile.Name))
					end
					for _, pfPos in ipairs(arrivalPath) do
						table.insert(waypoints, {
							type = "pathfind",
							position = Vector3.new(pfPos.X, arrivalSafeCenter.Y, pfPos.Z),
							tile = currTile
						})
					end
				else
					-- Strategy 2: Cell-based BFS pathfinding through tile's raster footprint
					local cellPath = TileAdjacencyManager.findCellPath(currTile, lastWP.position, arrivalSafeCenter)

					if #cellPath > 0 then
						if DEBUG then
							print(string.format(
								"[NPCMovement:Waypoints] Arrival cell-path: %d intermediates on %s (edge -> center)",
								#cellPath, currTile.Name))
						end
						for _, cellPos in ipairs(cellPath) do
							table.insert(waypoints, {
								type = "pathfind",
								position = Vector3.new(cellPos.X, arrivalSafeCenter.Y, cellPos.Z),
								tile = currTile
							})
						end
					else
						if DEBUG then
							print(string.format(
								"[NPCMovement:Waypoints] WARNING: No arrival path found on %s, using direct edge->center (may fall)",
								currTile.Name))
						end
					end
				end
			end
		end

		-- Tile safe center waypoint (always added)
		table.insert(waypoints, {
			type = "tile",
			tile = currTile,
			position = getTileSpawnPosition(currTile)
		})
	end

	if DEBUG then
		local wpSummary = ""
		for idx, wp in ipairs(waypoints) do
			wpSummary = wpSummary .. string.format("\n  [%d] %s at (%.1f, %.1f, %.1f)",
				idx, wp.type, wp.position.X, wp.position.Y, wp.position.Z)
			if wp.tile then
				wpSummary = wpSummary .. " (" .. wp.tile.Name .. ")"
			end
		end
		print("[NPCMovement:Waypoints] Built " .. #waypoints .. " enriched waypoints:" .. wpSummary)
	end

	return waypoints
end

-- Teleport with throttle and safe-center validation
-- FIX v9: Track consecutive falls and abort movement if too many
local function teleportToSafeTile(npcModel)
	getDependencies()

	if not npcModel or not npcModel.Parent then return false end

	movementStates[npcModel] = movementStates[npcModel] or {}
	local state = movementStates[npcModel]

	local now = os.clock()
	state.lastTeleport = state.lastTeleport or 0
	if now - state.lastTeleport < TELEPORT_MIN_INTERVAL then
		if DEBUG then warn("[NPCMovement] Teleport suppressed (throttle) for", npcModel.Name) end
		return false
	end

	-- FIX v9: Track consecutive fall recoveries
	state.fallRecoveries = state.fallRecoveries or 0
	state.lastFallRecovery = state.lastFallRecovery or 0

	-- Reset fall counter if enough time has passed since last fall
	if now - state.lastFallRecovery > FALL_RECOVERY_RESET_TIME then
		state.fallRecoveries = 0
	end

	state.fallRecoveries = state.fallRecoveries + 1
	state.lastFallRecovery = now

	-- FIX v9: If too many consecutive falls during movement, abort the movement
	-- Note: Can't call stopMovement() here due to function ordering, so we inline the critical parts
	if state.fallRecoveries > MAX_FALL_RECOVERIES and state.state == "Moving" then
		if DEBUG then
			print("[NPCMovement] ABORTING movement for " .. npcModel.Name .. " - too many fall recoveries (" .. state.fallRecoveries .. ")")
		end
		state.fallRecoveries = 0

		-- Inline movement cleanup (can't call stopMovement due to forward reference)
		local movement = activeMovements[npcModel]
		if movement then
			if movement.targetTileKey then
				if reservedTiles[movement.targetTileKey] == npcModel then
					reservedTiles[movement.targetTileKey] = nil
				end
			end
			if movement.connection then
				pcall(function() movement.connection:Disconnect() end)
			end
			activeMovements[npcModel] = nil
		end
		state.state = "Idle"
		state.moveAttempts = 0
		state.stuckSince = nil

		-- Stop humanoid movement
		local humanoid = getHumanoid(npcModel)
		local root = getRootPart(npcModel)
		if humanoid and root then
			humanoid:MoveTo(root.Position)
		end

		if DEBUG then
			print("[NPCMovement] " .. npcModel.Name .. " stopped, now Idle (fall abort)")
		end
		-- Continue with teleport to get NPC to safe position
	end

	local tileKey = npcModel:GetAttribute("TileKey")
	if not tileKey then return false end

	local tilePart = TileAdjacencyManager.getTileFromKey(tileKey)
	if not tilePart then
		tilePart = TileAdjacencyManager.getTileFromKeyWithFallback(tileKey)
	end
	if not tilePart then return false end

	local safePos = getTileSpawnPosition(tilePart)
	if not safePos then return false end

	-- Validate safePos roughly with raycast down
	local origin = safePos + Vector3.new(0, SAFE_CENTER_GROUND_TOLERANCE, 0)
	local ray = Workspace:Raycast(origin, Vector3.new(0, -SAFE_CENTER_GROUND_TOLERANCE * 2, 0), RaycastParams.new())
	if not ray then
		if DEBUG then warn("[NPCMovement] Safe center validation failed for", npcModel.Name, "tile", tilePart.Name) end
		-- still allow a fallback if humanoid exists: use current root's XZ with safe Y
		local root = getRootPart(npcModel)
		if root then
			safePos = Vector3.new(root.Position.X, safePos.Y, root.Position.Z)
		end
	end

	local root = getRootPart(npcModel)
	if root then
		local humanoid = getHumanoid(npcModel)
		if humanoid then
			humanoid:MoveTo(safePos)
		end

		root.AssemblyLinearVelocity = Vector3.new(0,0,0)
		npcModel:PivotTo(CFrame.new(safePos))
		state.lastTeleport = now

		if DEBUG then
			print("[NPCMovement] Teleported " .. npcModel.Name .. " back to safe position on " .. tilePart.Name .. " (falls: " .. state.fallRecoveries .. ")")
			makeDebugPart("Teleport_"..npcModel.Name, safePos + Vector3.new(0,1,0), Vector3.new(1,1,1), Color3.fromRGB(0,255,0), 2)
		end
		return true
	end

	return false
end

local function startGroundCheck(npcModel)
	-- Avoid duplicate
	if groundCheckConnections[npcModel] then return end

	local accumulator = 0
	groundCheckConnections[npcModel] = RunService.Heartbeat:Connect(function(dt)
		accumulator = accumulator + dt
		if accumulator < GROUND_CHECK_INTERVAL then return end
		accumulator = 0

		if not npcModel or not npcModel.Parent then
			if groundCheckConnections[npcModel] then
				groundCheckConnections[npcModel]:Disconnect()
				groundCheckConnections[npcModel] = nil
			end
			return
		end

		if not isOnValidGround(npcModel) then
			if DEBUG then
				print("[NPCMovement:GroundCheck] Triggering teleport recovery for " .. npcModel.Name)
			end
			teleportToSafeTile(npcModel)
		else
			-- FIX v6: snap idle drifters
			local state = NPCMovementSystem.getMovementState(npcModel)
			if state == "Idle" then
				local root = getRootPart(npcModel)
				local tileKey = npcModel:GetAttribute("TileKey")
				if root and tileKey then
					local tilePart = TileAdjacencyManager.getTileFromKey(tileKey)
					if tilePart then
						local safePos = getTileSpawnPosition(tilePart)
						if safePos then
							local driftXZ = ((root.Position - safePos) * Vector3.new(1,0,1)).Magnitude
							if driftXZ > IDLE_DRIFT_THRESHOLD then
								if DEBUG then
									print("[NPCMovement:GroundCheck] Drifting idle NPC " .. npcModel.Name .. " is " .. string.format("%.1f", driftXZ) .. " studs from center, snapping back")
								end
								root.AssemblyLinearVelocity = Vector3.new(0,0,0)
								npcModel:PivotTo(CFrame.new(safePos))
								local humanoid = getHumanoid(npcModel)
								if humanoid then humanoid:MoveTo(safePos) end
								if DEBUG then print("[NPCMovement] Snapped idle " .. npcModel.Name .. " back to center") end
							end
						end
					end
				end
			end
		end
	end)
end

---------------------------------------------------
-- State Management (unchanged API with additions)
---------------------------------------------------

function NPCMovementSystem.getMovementState(npcModel)
	local data = movementStates[npcModel]
	return data and data.state or "Idle"
end

function NPCMovementSystem.isMoving(npcModel)
	return NPCMovementSystem.getMovementState(npcModel) == "Moving"
end

function NPCMovementSystem.isRetreating(npcModel)
	return NPCMovementSystem.getMovementState(npcModel) == "Retreating"
end

function NPCMovementSystem.isIdle(npcModel)
	return NPCMovementSystem.getMovementState(npcModel) == "Idle"
end

function NPCMovementSystem.canBeSelected(npcModel)
	return not NPCMovementSystem.isRetreating(npcModel)
end

function NPCMovementSystem.canBeAttacked(npcModel)
	return not NPCMovementSystem.isRetreating(npcModel)
end

---------------------------------------------------
-- Tile Reservation (unchanged)
---------------------------------------------------

local function reserveTile(tileKey, npcModel)
	if reservedTiles[tileKey] and reservedTiles[tileKey] ~= npcModel then
		return false
	end
	reservedTiles[tileKey] = npcModel
	return true
end

local function releaseTileReservation(tileKey, npcModel)
	if reservedTiles[tileKey] == npcModel then
		reservedTiles[tileKey] = nil
	end
end

local function isTileReservedByOther(tileKey, npcModel)
	return reservedTiles[tileKey] ~= nil and reservedTiles[tileKey] ~= npcModel
end

---------------------------------------------------
-- Movement Monitoring (patched: stuck detection + retries)
---------------------------------------------------

local function stopMovement(npcModel, newState)
	local movement = activeMovements[npcModel]
	if movement then
		if movement.targetTileKey then
			releaseTileReservation(movement.targetTileKey, npcModel)
		end
		if movement.connection then
			pcall(function() movement.connection:Disconnect() end)
		end
		activeMovements[npcModel] = nil
	end

	movementStates[npcModel] = movementStates[npcModel] or {}
	movementStates[npcModel].state = newState or "Idle"
	movementStates[npcModel].moveAttempts = 0
	movementStates[npcModel].stuckSince = nil

	local humanoid = getHumanoid(npcModel)
	local root = getRootPart(npcModel)
	if humanoid and root then
		humanoid:MoveTo(root.Position)
	end

	if DEBUG then
		print("[NPCMovement] " .. npcModel.Name .. " stopped, now " .. (newState or "Idle"))
	end
end

local function safeCapitalCapture(tileCountry, owner)
	getDependencies()
	return TileOwnershipManager.captureCapital(tileCountry, owner)
end

-- Core monitor that checks arrival, stuckness, and triggers retries/teleports
local function monitorMovement(npcModel, isRetreat)
	getDependencies()

	local movement = activeMovements[npcModel]
	if not movement then return end

	local humanoid = getHumanoid(npcModel)
	local root = getRootPart(npcModel)
	if not humanoid or not root then
		stopMovement(npcModel, "Idle")
		return
	end

	-- FIX: Handle waypoint progression using enriched waypoints
	local enrichedWaypoints = movement.enrichedWaypoints
	local currentWaypoint = movement.currentWaypoint

	-- Guard: Validate enrichedWaypoints and currentWaypoint
	if not enrichedWaypoints or currentWaypoint > #enrichedWaypoints then
		stopMovement(npcModel, "Idle")
		return
	end

	local currentWP = enrichedWaypoints[currentWaypoint]
	local waypointPos = currentWP.position

	-- Guard: Validate waypointPos exists
	if not waypointPos then
		stopMovement(npcModel, "Idle")
		return
	end

	local distanceXZ = ((root.Position - waypointPos) * Vector3.new(1,0,1)).Magnitude

	-- Use tighter arrival threshold for edge waypoints (must reach edge precisely)
	local arrivalThreshold = (currentWP.type == "tile") and ARRIVAL_THRESHOLD or EDGE_ARRIVAL_THRESHOLD

	-- ARRIVAL AT WAYPOINT
	if distanceXZ <= arrivalThreshold then
		-- Snap to waypoint only for tile waypoints (snapping to edge could be risky)
		if currentWP.type == "tile" then
			npcModel:PivotTo(CFrame.new(waypointPos))
		end

		if isRetreat then
			if DEBUG then print("[NPCMovement] " .. npcModel.Name .. " retreat complete") end
			stopMovement(npcModel, "Idle")
			return
		end

		-- Check if we've reached the FINAL waypoint
		if currentWaypoint < #enrichedWaypoints then
			-- More waypoints ahead - move to next one
			currentWaypoint = currentWaypoint + 1
			movement.currentWaypoint = currentWaypoint
			local nextWP = enrichedWaypoints[currentWaypoint]

			if DEBUG then
				print("[NPCMovement:Waypoint] Reached waypoint " .. (currentWaypoint - 1) .. " (" .. currentWP.type .. "), moving to waypoint " .. currentWaypoint .. " (" .. nextWP.type .. ")")
			end

			-- GAP CROSSING FIX: When the NPC is at the departure edge and the next
			-- waypoint is the arrival edge on a different tile, skip the arrival edge
			-- and teleport to the first interior waypoint. This prevents the humanoid
			-- from failing to climb large height differences at tile edges (e.g. edge
			-- at Y=4.6 but tile interior at Y=7.6).
			if currentWP.type == "edge" and nextWP.type == "edge"
				and currentWP.tile ~= nextWP.tile then
				-- This is a gap crossing: currentWP = departure edge, nextWP = arrival edge
				-- Find the first non-edge waypoint after the arrival edge
				local landingIdx = currentWaypoint + 1
				if landingIdx <= #enrichedWaypoints then
					local landingWP = enrichedWaypoints[landingIdx]
					if DEBUG then
						print(string.format("[NPCMovement:GapCross] Teleporting %s past arrival edge to %s waypoint at (%.1f, %.1f, %.1f)",
							npcModel.Name, landingWP.type, landingWP.position.X, landingWP.position.Y, landingWP.position.Z))
					end
					-- Teleport NPC to the landing waypoint (first safe interior point)
					npcModel:PivotTo(CFrame.new(landingWP.position))
					local snapRoot = getRootPart(npcModel)
					if snapRoot then
						snapRoot.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
					end
					-- Advance past the arrival edge to the landing point
					currentWaypoint = landingIdx
					movement.currentWaypoint = currentWaypoint
					-- Now issue MoveTo for the NEXT waypoint after landing
					if currentWaypoint < #enrichedWaypoints then
						local afterLanding = enrichedWaypoints[currentWaypoint + 1]
						if humanoid and afterLanding then
							humanoid:MoveTo(afterLanding.position)
						end
					end
					-- Next monitorMovement iteration will handle arrival at landing or further progression
					return
				else
					-- No interior waypoint after arrival edge — teleport to arrival edge
					-- with Y adjusted to tile center height to avoid low-edge climb problem
					local safeCenter = getTileSpawnPosition(nextWP.tile)
					local adjustedY = safeCenter and safeCenter.Y or nextWP.position.Y
					local adjustedPos = Vector3.new(nextWP.position.X, adjustedY, nextWP.position.Z)
					if DEBUG then
						print(string.format("[NPCMovement:GapCross] Teleporting %s to adjusted arrival edge at (%.1f, %.1f, %.1f)",
							npcModel.Name, adjustedPos.X, adjustedPos.Y, adjustedPos.Z))
					end
					npcModel:PivotTo(CFrame.new(adjustedPos))
					local snapRoot = getRootPart(npcModel)
					if snapRoot then
						snapRoot.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
					end
				end
			end

			local nextWaypointPosition = enrichedWaypoints[currentWaypoint].position
			if humanoid and nextWaypointPosition then
				humanoid:MoveTo(nextWaypointPosition)
			end
			return
		end

		-- FINAL DESTINATION REACHED: occupancy / capture logic
		local targetTileKey = movement.targetTileKey
		local originTileKey = movement.originTileKey
		local owner = Combat.getOwner(npcModel)
		local role = Combat.getRole(npcModel)

		local targetTilePart = TileAdjacencyManager.getTileFromKey(targetTileKey)
		local tileCountry = TileAdjacencyManager.getTileCountry(targetTilePart)
		local playerCountry = owner and TileManager.getPlayerCountry(owner)

		local currentOccupant = TileManager.getTileOccupant(targetTileKey)
		local isOccupiedByOther = currentOccupant ~= nil and currentOccupant ~= npcModel

		if isOccupiedByOther then
			if DEBUG then print("[NPCMovement] " .. npcModel.Name .. " tile occupied by " .. currentOccupant.Name .. ", retreating") end
			NPCMovementSystem.startRetreat(npcModel, originTileKey, movement.originPosition)
			return
		else
			-- release old tile
			if originTileKey then
				TileManager.releaseTile(npcModel:GetAttribute("Country"), originTileKey)
			end

			-- occupy new tile
			TileManager.occupyTileGlobal(targetTileKey, npcModel)
			npcModel:SetAttribute("TileKey", targetTileKey)

			if tileCountry and tileCountry ~= playerCountry and role == "Attacker" then
				TileOwnershipManager.captureTile(targetTilePart, owner)

				-- FIX: Check if this tile is the ACTUAL capital of the country being invaded
				-- tileCountry = geographic region name (e.g., "Germany"), never changes even after conquest
				local actualCapital = TileManager.getCountryCapital(tileCountry)

				if actualCapital and targetTilePart == actualCapital then
					-- CRITICAL GUARD: Only trigger capital conquest if the region is still "alive"
					-- (owned by a Player, not already conquered)
					-- FIX: Use ServerState.resolveCountryOwner() to handle conquest chains
					-- Example: France → Conquered_Germany → Conquered_Poland → PlayerPolish
					local currentOwner = ServerState.resolveCountryOwner(tileCountry)

					-- Check if the chain resolves to an active Player
					if currentOwner and typeof(currentOwner) == "Instance" and currentOwner:IsA("Player") then
						-- This is the region's capital AND the region is ultimately owned by a live player
						safeCapitalCapture(tileCountry, owner)
					else
						-- Region is conquered (chain resolves to nil or non-Player) - treat as normal tile capture
						if DEBUG then
							print(string.format("[NPCMovement] Captured %s's capital, but %s is already conquered (resolved owner: %s)",
								tileCountry, tileCountry, tostring(currentOwner or "nil")))
						end
					end
				end
			elseif tileCountry and tileCountry == playerCountry then
				if TileOwnershipManager.isOccupied(targetTilePart) and not TileOwnershipManager.isOccupiedBy(targetTilePart, owner) then
					TileOwnershipManager.reclaimTile(targetTilePart, owner)
				end
			end

			if DEBUG then print("[NPCMovement] " .. npcModel.Name .. " arrived at " .. targetTileKey) end
			stopMovement(npcModel, "Idle")
			return
		end
	end

	-- STILL MOVING: Apply path correction to keep NPC on safe corridor
	local effectiveTarget = waypointPos

	-- NOTE: Active edge detection disabled during movement
	-- The ground check loop (every 0.1s) is sufficient to catch actual falls
	-- Active edge detection was too aggressive and caused NPCs to get stuck
	-- from momentary loss of ground contact during humanoid movement (normal behavior)

	-- Path correction: keep NPC in a safe corridor between consecutive waypoints
	-- Uses previous waypoint as corridor origin (not global origin) for per-segment accuracy
	local corridorOrigin = nil
	if currentWaypoint > 1 then
		corridorOrigin = enrichedWaypoints[currentWaypoint - 1].position
	else
		corridorOrigin = movement.originPosition
	end

	if corridorOrigin then
		effectiveTarget = getPathCorrectedPosition(npcModel, corridorOrigin, waypointPos)
	end

	humanoid:MoveTo(effectiveTarget)

	-- STUCK detection sampling
	movementStates[npcModel] = movementStates[npcModel] or {}
	local state = movementStates[npcModel]

	local now = os.clock()
	state.lastSamplePos = state.lastSamplePos or root.Position
	state.lastSampleTime = state.lastSampleTime or now
	state.stuckSince = state.stuckSince or nil
	state.moveAttempts = state.moveAttempts or 0

	if now - state.lastSampleTime >= STUCK_CHECK_TIME then
		local moved = (root.Position - state.lastSamplePos).Magnitude
		if moved < STUCK_DISTANCE_THRESHOLD then
			-- flagged as stuck
			if not state.stuckSince then
				state.stuckSince = now
			end
		else
			state.stuckSince = nil
		end
		state.lastSamplePos = root.Position
		state.lastSampleTime = now
	end

	-- If stuck for long enough, try to recover
	if state.stuckSince and (os.clock() - state.stuckSince) > (STUCK_CHECK_TIME * 1.5) then
		state.moveAttempts = (state.moveAttempts or 0) + 1
		if state.moveAttempts <= MAX_MOVE_RETRIES then
			-- retry MoveTo with backoff
			if DEBUG then print("[NPCMovement] Stuck detected for", npcModel.Name, "retrying MoveTo (attempt)", state.moveAttempts) end
			task.delay(MOVE_RETRY_BACKOFF * state.moveAttempts, function()
				local h = getHumanoid(npcModel)
				if h and npcModel and npcModel.Parent then
					h:MoveTo(waypointPos)
				end
			end)
			-- reset stuck timer to allow the retry to take effect
			state.stuckSince = nil
		else
			-- attempts exhausted -> fallback: either retreat or teleport
			if isRetreat then
				-- if already retreating, teleport directly to origin
				if DEBUG then print("[NPCMovement] Retreat stuck; teleporting", npcModel.Name) end
				teleportToSafeTile(npcModel)
				stopMovement(npcModel, "Idle")
			else
				if DEBUG then print("[NPCMovement] Move attempts exhausted; teleporting back to origin for", npcModel.Name) end
				-- teleport to originPosition (safe fallback)
				if movement.originPosition then
					-- try to pivot to origin position (center of origin tile)
					local ok = pcall(function() npcModel:PivotTo(CFrame.new(movement.originPosition)) end)
					if not ok then teleportToSafeTile(npcModel) end
				else
					teleportToSafeTile(npcModel)
				end
				stopMovement(npcModel, "Idle")
			end
		end
	end
end

---------------------------------------------------
-- canMoveToTile (unchanged semantics)
---------------------------------------------------

local function canMoveToTile(owner, role, targetTilePart, playerCountry)
	getDependencies()

	local tileCountry = TileAdjacencyManager.getTileCountry(targetTilePart)

	-- Own territory - always allowed
	if tileCountry == playerCountry then
		return true, nil
	end

	-- Already occupied by us - always allowed
	if TileOwnershipManager.isOccupiedBy(targetTilePart, owner) then
		return true, nil
	end

	-- Different country
	if tileCountry and tileCountry ~= playerCountry then
		local CountryOwners = ServerState.getCountryOwners()
		local tileOwner = CountryOwners[tileCountry]

		-- Conquered territory check
		if type(tileOwner) == "string" and tileOwner:find("Conquered_") then
			local conquerorCountry = tileOwner:gsub("Conquered_", "")
			if conquerorCountry == playerCountry then
				return true, nil
			end
			-- FIX v9: Handle conquered territory owned by someone else
			-- Check if allied with the conqueror
			if DiplomacyManager.areCountriesAllied(playerCountry, conquerorCountry) then
				return true, nil
			end
			-- Defenders cannot move to enemy-conquered territory
			if role == "Defender" then
				return false, "Defenders cannot move to enemy-conquered territory"
			end
			-- Attackers need war with the conqueror to pass
			if not DiplomacyManager.areCountriesAtWar(playerCountry, conquerorCountry) then
				return false, "Not at war with " .. conquerorCountry .. " (conqueror of " .. tileCountry .. ")"
			end
			return true, nil
		end

		-- Defenders cannot move to enemy territory
		if role == "Defender" then
			return false, "Defenders cannot move to enemy territory"
		end

		-- For attackers: check war status
		if typeof(tileOwner) == "Instance" and tileOwner:IsA("Player") then
			if not DiplomacyManager.areAtWar(owner, tileOwner) then
				return false, "Not at war with " .. tileCountry
			end
			return true, nil
		elseif tileOwner == "Unowned" then
			return false, "Cannot invade neutral territory (" .. tileCountry .. " is unowned)"
		end
	end

	return true, nil
end

---------------------------------------------------
-- startMovement (patched: set up movementState fields + startGroundCheck)
---------------------------------------------------

function NPCMovementSystem.startMovement(npcModel, targetTileKey, targetTilePart)
	getDependencies()

	if not npcModel or not targetTileKey then return false, "Invalid parameters" end

	local owner = Combat.getOwner(npcModel)
	local role = Combat.getRole(npcModel)

	if not owner then return false, "NPC has no owner" end

	if NPCMovementSystem.isRetreating(npcModel) then
		return false, "NPC is retreating"
	end

	if NPCMovementSystem.isMoving(npcModel) then
		stopMovement(npcModel, "Idle")
	end

	local currentTileKey = npcModel:GetAttribute("TileKey")
	if not currentTileKey then
		return false, "NPC has no current tile"
	end

	local resolvedTargetTilePart = targetTilePart
	if not resolvedTargetTilePart then
		resolvedTargetTilePart = TileAdjacencyManager.getTileFromKey(targetTileKey)
		if DEBUG and resolvedTargetTilePart then
			print("[NPCMovement:Resolution] Target tile resolved via getTileFromKey: " .. tostring(targetTileKey) .. " -> " .. resolvedTargetTilePart.Name)
		end
	end
	if not resolvedTargetTilePart then
		resolvedTargetTilePart = TileAdjacencyManager.getTileFromKeyWithFallback(targetTileKey)
		if DEBUG then
			if resolvedTargetTilePart then
				print("[NPCMovement:Resolution] WARNING: Target tile resolved via fallback method: " .. tostring(targetTileKey) .. " -> " .. resolvedTargetTilePart.Name)
			else
				print("[NPCMovement:Resolution] ERROR: Target tile FAILED to resolve even with fallback: " .. tostring(targetTileKey))
			end
		end
	end
	if not resolvedTargetTilePart then
		if DEBUG then
			print("[NPCMovement] BLOCKED: Cannot resolve target tile " .. tostring(targetTileKey))
		end
		return false, "Invalid target tile"
	end

	local currentTilePart = TileAdjacencyManager.getTileFromKey(currentTileKey)
	-- local currentTileResolutionMethod = "getTileFromKey"
	if currentTilePart and DEBUG then
		print("[NPCMovement:Resolution] Current tile resolved via getTileFromKey: " .. tostring(currentTileKey) .. " -> " .. currentTilePart.Name)
	end
	if not currentTilePart then
		currentTilePart = TileAdjacencyManager.getTileFromKeyWithFallback(currentTileKey)
		-- currentTileResolutionMethod = "getTileFromKeyWithFallback"
		if DEBUG then
			if currentTilePart then
				print("[NPCMovement:Resolution] WARNING: Current tile resolved via fallback: " .. tostring(currentTileKey) .. " -> " .. currentTilePart.Name)
			else
				print("[NPCMovement:Resolution] ERROR: Current tile FAILED to resolve even with fallback: " .. tostring(currentTileKey))
			end
		end
	end

	-- local targetTileResolutionMethod = "getTileFromKey"
	if targetTilePart and targetTilePart == resolvedTargetTilePart then
		-- targetTileResolutionMethod = "provided as parameter"
	elseif string.find(tostring(resolvedTargetTilePart), "getTileFromKeyWithFallback") then
		-- targetTileResolutionMethod = "getTileFromKeyWithFallback"
	end

	-- FIX v10: Validate NPC is actually near its resolved tile (defense-in-depth for TileKey mismatch)
	if currentTilePart then
		local root = getRootPart(npcModel)
		if root then
			local npcPosXZ = root.Position * Vector3.new(1, 0, 1)
			local tilePosXZ = currentTilePart.Position * Vector3.new(1, 0, 1)
			local tileDistance = (npcPosXZ - tilePosXZ).Magnitude

			if tileDistance > currentTilePart.Size.Magnitude / 2 + 5 then
				local correctedTile = TileAdjacencyManager.getTileUnderPosition(root.Position)
				if correctedTile then
					if DEBUG then
						print("[NPCMovement:Resolution] TileKey mismatch corrected: " .. currentTilePart.Name .. " -> " .. correctedTile.Name .. " (NPC was " .. math.floor(tileDistance) .. " studs away)")
					end
					currentTilePart = correctedTile
					local correctedKey = TileManager.getTileKeyFromPart(correctedTile)
					if correctedKey then
						currentTileKey = correctedKey
						npcModel:SetAttribute("TileKey", correctedKey)
					end
				end
			end
		end
	end

	-- STRICT VALIDATION: Reject movement if current tile fails to resolve properly
	-- This prevents using the weaker key-based fallback adjacency check
	if not currentTilePart then
		if DEBUG then
			print("[NPCMovement] BLOCKED: Current tile failed to resolve: " .. tostring(currentTileKey))
		end
		return false, "Cannot determine current tile position"
	end

	-- FIX: Use ONLY the reliable rasterization-based method, never fallback to weaker key-based method
	-- The key-based method uses raycast fallback which can return incorrect tiles on irregular terrain
	if not currentTilePart or not resolvedTargetTilePart then
		if DEBUG then
			print("[NPCMovement] BLOCKED: Cannot use reliable adjacency check - tile parts not properly resolved")
			if not currentTilePart then
				print("  - Current tile failed to resolve: " .. tostring(currentTileKey))
			end
			if not resolvedTargetTilePart then
				print("  - Target tile failed to resolve: " .. tostring(targetTileKey))
			end
		end
		return false, "Cannot determine if tiles are adjacent - resolution failed"
	end

	-- FIX v10: If tiles are directly adjacent, use direct 2-tile path (skip BFS)
	-- This prevents routing through intermediate tiles when the destination is right next door.
	-- Diplomacy/occupancy for the destination is checked separately by canMoveToTile below.
	local playerCountry = TileManager.getPlayerCountry(owner)
	local areTilesDirectlyAdjacent = TileAdjacencyManager.areTilesAdjacent(currentTilePart, resolvedTargetTilePart)
	local tilePath

	if areTilesDirectlyAdjacent then
		tilePath = {currentTilePart, resolvedTargetTilePart}
		if DEBUG then
			print("[NPCMovement:Pathfinding] Direct adjacent move: " .. currentTilePart.Name .. " -> " .. resolvedTargetTilePart.Name)
		end
	else
		-- Multi-tile pathfinding with diplomacy validation (for non-adjacent destinations)
		tilePath = findTilePath(currentTilePart, resolvedTargetTilePart, nil, owner, role, playerCountry)
	end

	if not tilePath then
		if DEBUG then
			print("[NPCMovement] No path found from " .. currentTilePart.Name .. " to " .. resolvedTargetTilePart.Name)
		end
		return false, "Cannot reach target tile"
	end

	if DEBUG and not areTilesDirectlyAdjacent then
		local pathStr = currentTilePart.Name
		for i = 2, #tilePath do
			pathStr = pathStr .. " -> " .. tilePath[i].Name
		end
		print("[NPCMovement:Pathfinding] Found path: " .. pathStr)
	end

	-- NOTE: Path validation disabled - the edge detection and ground checks during movement
	-- are more flexible and handle minor gaps better. The humanoid controller can bridge
	-- small terrain variations, and our ground checks will catch actual fall-off situations.

	-- FIX v8: playerCountry already defined above for pathfinding
	local canMove, moveError = canMoveToTile(owner, role, resolvedTargetTilePart, playerCountry)
	if not canMove then
		return false, moveError
	end

	-- Occupancy check
	local currentOccupant = TileManager.getTileOccupant(targetTileKey)
	if currentOccupant and currentOccupant ~= npcModel then
		return false, "Tile is occupied by another NPC"
	end

	-- Reservation check - ALLOW competitive movement
	-- We check if reserved, but we DO NOT stop movement. 
	-- Multiple NPCs can now race to the same tile.
	if isTileReservedByOther(targetTileKey, npcModel) then
		if DEBUG then
			print("[NPCMovement] " .. npcModel.Name .. " represents a race condition: moving to reserved tile " .. targetTileKey)
		end
		-- PROCEED anyway, do not return false
	end

	-- Try to reserve, but process even if failed (competitive)
	if not reserveTile(targetTileKey, npcModel) then
		if DEBUG then
			print("[NPCMovement] Could not reserve " .. targetTileKey .. " (likely taken), but moving anyway")
		end
		-- Continue to move even if reservation failed
	end

	-- Positions
	local targetPosition = getTileSpawnPosition(resolvedTargetTilePart)
	local originTilePart = TileAdjacencyManager.getTileFromKey(currentTileKey)
	if not originTilePart then
		local root = getRootPart(npcModel)
		if root then
			originTilePart = TileAdjacencyManager.getTileUnderPosition(root.Position)
		end
	end
	local originPosition = originTilePart and getTileSpawnPosition(originTilePart) or getRootPart(npcModel).Position
	if not targetPosition then
		releaseTileReservation(targetTileKey, npcModel)
		return false, "Could not calculate target position"
	end

	-- Set up movement state
	movementStates[npcModel] = movementStates[npcModel] or {}
	movementStates[npcModel].state = "Moving"
	movementStates[npcModel].lastTeleport = movementStates[npcModel].lastTeleport or 0
	movementStates[npcModel].lastSamplePos = getRootPart(npcModel) and getRootPart(npcModel).Position or Vector3.new(0,0,0)
	movementStates[npcModel].lastSampleTime = os.clock()
	movementStates[npcModel].stuckSince = nil
	movementStates[npcModel].moveAttempts = 0
	movementStates[npcModel].fallRecoveries = 0  -- FIX v9: Reset fall recovery counter on new movement

	-- Build enriched waypoints with edge-crossing points for gap tiles
	local enrichedWaypoints = buildEnrichedWaypoints(tilePath)
	if not enrichedWaypoints or #enrichedWaypoints < 2 then
		releaseTileReservation(targetTileKey, npcModel)
		return false, "Failed to build waypoints"
	end

	activeMovements[npcModel] = {
		targetTileKey = targetTileKey,
		originTileKey = currentTileKey,
		targetPosition = targetPosition,
		originPosition = originPosition,
		tilePath = tilePath,                    -- keep original for reference
		enrichedWaypoints = enrichedWaypoints,  -- enriched path with edge-crossing points
		currentWaypoint = 2,                    -- index into enrichedWaypoints (skip first)
		connection = nil
	}

	-- Move to the first enriched waypoint position
	local firstWaypointPos = enrichedWaypoints[2].position

	local humanoid = getHumanoid(npcModel)
	if humanoid and firstWaypointPos then
		humanoid:MoveTo(firstWaypointPos)
	end

	-- monitor loop
	local connection
	connection = RunService.Heartbeat:Connect(function()
		if not npcModel or not npcModel.Parent then
			pcall(function() connection:Disconnect() end)
			return
		end
		monitorMovement(npcModel, false)
	end)
	activeMovements[npcModel].connection = connection

	-- start ground check
	startGroundCheck(npcModel)

	if DEBUG then
		print("[NPCMovement] " .. npcModel.Name .. " moving from " .. currentTileKey .. " to " .. targetTileKey)
		makeDebugPart("MoveTarget_"..npcModel.Name, targetPosition + Vector3.new(0,1,0), Vector3.new(0.8,0.8,0.8), Color3.fromRGB(0,150,255), 2)
	end

	return true
end

---------------------------------------------------
-- startRetreat (patched: release & reset state)
---------------------------------------------------

function NPCMovementSystem.startRetreat(npcModel, originTileKey, originPosition)
	getDependencies()

	if not npcModel then return end

	local movement = activeMovements[npcModel]
	if movement then
		if movement.targetTileKey then releaseTileReservation(movement.targetTileKey, npcModel) end
		if movement.connection then pcall(function() movement.connection:Disconnect() end) end
	end

	movementStates[npcModel] = movementStates[npcModel] or {}
	movementStates[npcModel].state = "Retreating"
	movementStates[npcModel].moveAttempts = 0
	movementStates[npcModel].stuckSince = nil

	local tileKey = originTileKey or npcModel:GetAttribute("TileKey")
	local tilePart = TileAdjacencyManager.getTileFromKey(tileKey)
	local targetPos = originPosition or (tilePart and getTileSpawnPosition(tilePart))

	if not targetPos then
		local root = getRootPart(npcModel)
		if root then targetPos = root.Position else stopMovement(npcModel, "Idle"); return end
	end

	activeMovements[npcModel] = {
		targetTileKey = tileKey,
		originTileKey = tileKey,
		targetPosition = targetPos,
		originPosition = targetPos,
		enrichedWaypoints = {
			{ type = "tile", position = targetPos, tile = tilePart },
			{ type = "tile", position = targetPos, tile = tilePart }
		},
		currentWaypoint = 2,
		connection = nil
	}

	local humanoid = getHumanoid(npcModel)
	if humanoid then humanoid:MoveTo(targetPos) end

	local connection
	connection = RunService.Heartbeat:Connect(function()
		if not npcModel or not npcModel.Parent then pcall(function() connection:Disconnect() end); return end
		monitorMovement(npcModel, true)
	end)
	activeMovements[npcModel].connection = connection

	if DEBUG then print("[NPCMovement] " .. npcModel.Name .. " retreating (invulnerable)") end
end

function NPCMovementSystem.cancelMovement(npcModel)
	if NPCMovementSystem.isRetreating(npcModel) then
		return false
	end
	stopMovement(npcModel, "Idle")
	return true
end

---------------------------------------------------
-- OnOwnerChanged: reset movement state when ownership transfers
---------------------------------------------------

function NPCMovementSystem.OnOwnerChanged(npcModel)
	if not npcModel then return end
	movementStates[npcModel] = movementStates[npcModel] or {}
	movementStates[npcModel].state = "Idle"
	movementStates[npcModel].stuckSince = nil
	movementStates[npcModel].moveAttempts = 0

	-- release any reservation this NPC had on other tiles if present
	for k, v in pairs(reservedTiles) do
		if v == npcModel then reservedTiles[k] = nil end
	end

	-- Stop active movement monitor
	local movement = activeMovements[npcModel]
	if movement and movement.connection then
		pcall(function() movement.connection:Disconnect() end)
	end
	activeMovements[npcModel] = nil

	if DEBUG then print("[NPCMovement] OnOwnerChanged: reset movement state for", npcModel.Name) end
end

---------------------------------------------------
-- Cleanup
---------------------------------------------------

function NPCMovementSystem.unregisterNPC(npcModel)
	-- Clean up ground check
	if groundCheckConnections[npcModel] then
		groundCheckConnections[npcModel]:Disconnect()
		groundCheckConnections[npcModel] = nil
	end

	-- Clean up movement & reservations
	local movement = activeMovements[npcModel]
	if movement and movement.targetTileKey then
		releaseTileReservation(movement.targetTileKey, npcModel)
	end

	stopMovement(npcModel, nil)
	movementStates[npcModel] = nil
	activeMovements[npcModel] = nil
end

-- Watch for NPC removals via Tag
-- Initialize logic
local function init()
	local NPC_TAG = "RegisteredNPC"

	-- Handle removals
	CollectionService:GetInstanceRemovedSignal(NPC_TAG):Connect(function(child)
		if movementStates[child] or groundCheckConnections[child] then
			NPCMovementSystem.unregisterNPC(child)
		end
	end)

	-- Handle existing
	for _, child in ipairs(CollectionService:GetTagged(NPC_TAG)) do
		startGroundCheck(child)
	end

	-- Handle additions
	CollectionService:GetInstanceAddedSignal(NPC_TAG):Connect(function(child)
		-- Wait for components to replicate/initialize
		task.defer(function()
			local attempts = 0
			while attempts < 10 do
				if child:FindFirstChild("Humanoid") and child:FindFirstChild("NPCOwner") then
					startGroundCheck(child)
					return
				end
				task.wait(0.1)
				attempts = attempts + 1
			end
		end)
	end)
end

-- Run init
task.spawn(init)

return NPCMovementSystem