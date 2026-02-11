-- UnitManager (ModuleScript in ServerScriptService - FINAL FIX FOR STACKING) - FIXED
-- FIX #5: Added PlayerRemoving cleanup to prevent memory leak
local Players = game:GetService("Players")

local UnitManager = {}
local TileKeyUtils = require(game.ServerScriptService:WaitForChild("TileKeyUtils", 10))

-- Key: Player object | Value: Table of Units 
local PlayerUnits = {}
local UnitIDCounter = 0

-- CRITICAL CONFIG: These must be consistent with TileManager
local UNIT_SPACING = 5 -- Minimum studs between NPCs so they don't overlap

-- Public API: Register a new unit
function UnitManager.registerUnit(player, npcModel, unitType)
	if not PlayerUnits[player] then
		PlayerUnits[player] = {}
	end

	UnitIDCounter += 1
	local unitID = UnitIDCounter

	PlayerUnits[player][npcModel] = {
		ID = unitID,
		Type = unitType,
		Model = npcModel,
		Position = npcModel:GetPivot().Position -- Will be updated upon spawn
	}

	npcModel.AncestryChanged:Once(function(_, newParent)
		if not newParent then
			UnitManager.deregisterUnit(player, npcModel)
		end
	end)

	return unitID
end

-- Public API: Deregister a unit upon destruction
function UnitManager.deregisterUnit(player, npcModel)
	if PlayerUnits[player] and PlayerUnits[player][npcModel] then
		PlayerUnits[player][npcModel] = nil

		if next(PlayerUnits[player]) == nil then
			PlayerUnits[player] = nil 
		end

		print("DEBUG: Deregistered unit " .. tostring(npcModel.Name))
	end
end

-- Public API: Gets all unit models and positions for a player
function UnitManager.getPlayerUnits(player)
	return PlayerUnits[player] or {}
end

-- Public API: Checks if a position is too close to an existing unit
function UnitManager.isPositionOccupied(player, potentialPosition)
	local units = UnitManager.getPlayerUnits(player)

	-- 1. Get the High-Res Fingerprint for where the player wants to move
	local potentialKey = TileKeyUtils.getTileKey(potentialPosition)

	for npcModel, unitData in pairs(units) do
		-- 2. Get the Fingerprint of where the existing NPC is
		local existingKey = TileKeyUtils.getTileKey(unitData.Position)

		-- 3. Check for "Key Stacking"
		-- If the keys match, they are effectively in the same 1-stud spot
		if existingKey == potentialKey then
			return true 
		end

		-- 4. Check for Physical Overlap (The "Personal Bubble")
		-- Even if keys don't match, they might be 2 studs apart. 
		-- This prevents NPCs from clipping into each other's shoulders.
		if (unitData.Position - potentialPosition).Magnitude < UNIT_SPACING then
			return true 
		end
	end

	return false
end

-- Public API: Updates a unit's stored position after it is moved
function UnitManager.updateUnitPosition(player, npcModel, newPosition)
	if PlayerUnits[player] and PlayerUnits[player][npcModel] then
		PlayerUnits[player][npcModel].Position = newPosition
	end
end

-- FIX #5: Clean up player data when they leave to prevent memory leaks
function UnitManager.clearPlayerUnits(player)
	if PlayerUnits[player] then
		PlayerUnits[player] = nil
		print("DEBUG: Cleared all units for player " .. player.Name)
	end
end

-- FIX #5: Connect to PlayerRemoving to automatically clean up
Players.PlayerRemoving:Connect(function(player)
	UnitManager.clearPlayerUnits(player)
end)

return UnitManager