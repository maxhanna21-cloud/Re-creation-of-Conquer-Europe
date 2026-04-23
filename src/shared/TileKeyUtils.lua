-- TileKeyUtils (ModuleScript)
local TileKeyUtils = {}

local TILE_GRID_SIZE = 1 -- Keep 1-stud for high precision on irregular tiles

function TileKeyUtils.getTileKey(position)
	-- Using math.round for consistent "fingerprinting" of a position
	local x = math.round(position.X)
	local z = math.round(position.Z)
	return x .. "," .. z
end

-- New Helper: Returns the rounded Vector3 so UnitManager can compare distances accurately
function TileKeyUtils.getRoundedPosition(position)
	return Vector3.new(math.round(position.X), position.Y, math.round(position.Z))
end

-- Parse a tile key back into X, Z coordinates
function TileKeyUtils.parseKey(tileKey)
	if not tileKey or type(tileKey) ~= "string" then
		return nil, nil
	end

	local x, z = tileKey:match("^(-?%d+),(-?%d+)$")
	if x and z then
		return tonumber(x), tonumber(z)
	end
	return nil, nil
end

-- Get tile key from a BasePart (tile)
-- Uses the spawn position (top center of tile + offset)
function TileKeyUtils.getTileKeyFromPart(tilePart)
	if not tilePart or not tilePart:IsA("BasePart") then 
		return nil 
	end

	-- Use spawn position like elsewhere (top of tile + 3 studs)
	local spawnPos = tilePart.Position + Vector3.new(0, tilePart.Size.Y / 2 + 3, 0)
	return TileKeyUtils.getTileKey(spawnPos)
end

-- Check if two tile keys are the same
function TileKeyUtils.areKeysEqual(keyA, keyB)
	return keyA == keyB
end

-- Validate that a tile key is properly formatted
function TileKeyUtils.isValidKey(tileKey)
	if not tileKey or type(tileKey) ~= "string" then
		return false
	end

	local x, z = TileKeyUtils.parseKey(tileKey)
	return x ~= nil and z ~= nil
end

return TileKeyUtils