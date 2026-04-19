-- TileCursor LocalScript
-- Combines:
--  - LRU caching & eviction (from v5)
--  - Strict disabling of Highlight/SelectionBox when not in use (from v12)
--  - Name/size filters, safe clone of cursor, robust cleanup

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Player = Players.LocalPlayer
local Mouse = Player:GetMouse()

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------
local DEBUG_HOVER = false
local MAX_TILE_SIZE = 300
local CACHE_MAX_SIZE = 500
local CACHE_EVICT_COUNT = 250 -- how many oldest entries to evict when full
local MAX_HIERARCHY_DEPTH = 20

local IGNORE_NAMES = {
	["ocean"] = true, ["water"] = true, ["sea"] = true,
	["background"] = true, ["baseplate"] = true, ["base"] = true,
	["hitbox"] = true, ["bounds"] = true, ["map"] = true,
	["visuals"] = true, ["meshes"] = true, ["terrain"] = true,
	["folder"] = true, ["countries"] = true, ["oceanfront"] = true
}

--------------------------------------------------------------------------------
-- ASSETS
--------------------------------------------------------------------------------
local OriginalCursor = ReplicatedStorage:WaitForChild("TileCursor", 10)
if not OriginalCursor then
	warn("[TileCursor] CRITICAL: TileCursor not found in ReplicatedStorage")
	return
end

-- Make a local clone so we can safely toggle/Destroy it without affecting other clients
local Cursor = OriginalCursor:Clone()
Cursor.Name = "LocalTileCursor"
Cursor.Parent = Workspace

-- Ensure cursor starts OFF (prevents highlight parent fallback)
if Cursor:IsA("Highlight") then
	Cursor.Enabled = false
elseif Cursor:IsA("SelectionBox") then
	Cursor.Visible = false
end

local EuropeMap = Workspace:WaitForChild("EuropeMap", 10)
if not EuropeMap then
	warn("[TileCursor] EuropeMap not found in Workspace")
	-- keep script alive, but nothing to highlight
end

--------------------------------------------------------------------------------
-- CACHE (LRU)
--------------------------------------------------------------------------------
-- countryModelCache[part] = { countryModel = Model or false, lastAccess = number }
local countryModelCache = {}
local cacheAccessOrder = {} -- array of parts, oldest at index 1

local function touchCacheEntry(part)
	-- remove existing occurrence
	for i = #cacheAccessOrder, 1, -1 do
		if cacheAccessOrder[i] == part then
			table.remove(cacheAccessOrder, i)
			break
		end
	end
	table.insert(cacheAccessOrder, part) -- newest on the end
end

local function evictOldestEntries()
	while #cacheAccessOrder > CACHE_MAX_SIZE do
		-- remove CACHE_EVICT_COUNT or until under limit
		local removed = 0
		for i = 1, CACHE_EVICT_COUNT do
			if #cacheAccessOrder == 0 then break end
			local oldPart = table.remove(cacheAccessOrder, 1)
			if oldPart then
				countryModelCache[oldPart] = nil
			end
			removed = removed + 1
		end
		-- safety: if nothing removed, break to avoid infinite loop
		if removed == 0 then break end
	end
end

--------------------------------------------------------------------------------
-- UTIL
--------------------------------------------------------------------------------
local function isIgnored(name)
	if not name then return false end
	return IGNORE_NAMES[string.lower(name)] == true
end

local function validatePartCandidate(part)
	if not part or not part:IsA("BasePart") then return false end
	if isIgnored(part.Name) then return false end
	-- size check: ignore huge parts that are likely background/baseplates
	-- use absolute magnitudes of X and Z
	if part.Size and (part.Size.X > MAX_TILE_SIZE or part.Size.Z > MAX_TILE_SIZE) then
		return false
	end
	-- ignore fully transparent parts
	if part.Transparency and part.Transparency >= 1 then
		return false
	end
	return true
end

--------------------------------------------------------------------------------
-- getCountryModel: walk up to find a model whose parent is EuropeMap
-- Returns Model or nil. Uses cache (LRU).
--------------------------------------------------------------------------------
local function getCountryModel(part)
	if not part or not validatePartCandidate(part) then
		return nil
	end

	-- cache check
	local cached = countryModelCache[part]
	if cached ~= nil then
		-- update LRU order
		touchCacheEntry(part)
		cached.lastAccess = tick()
		return cached.countryModel or nil
	end

	-- if the part is directly a child of EuropeMap, treat as non-country tile
	if part.Parent == EuropeMap then
		countryModelCache[part] = { countryModel = false, lastAccess = tick() }
		touchCacheEntry(part)
		evictOldestEntries()
		return nil
	end

	-- walk up
	local current = part.Parent
	local depth = 0
	while current and current ~= EuropeMap and current ~= Workspace and depth < MAX_HIERARCHY_DEPTH do
		-- if we found a direct child of EuropeMap
		if current.Parent == EuropeMap then
			-- validate name
			if isIgnored(current.Name) then
				countryModelCache[part] = { countryModel = false, lastAccess = tick() }
				touchCacheEntry(part)
				evictOldestEntries()
				return nil
			end
			-- accept as country model
			countryModelCache[part] = { countryModel = current, lastAccess = tick() }
			touchCacheEntry(part)
			evictOldestEntries()
			return current
		end
		current = current.Parent
		depth = depth + 1
	end

	-- nothing found — cache negative result
	countryModelCache[part] = { countryModel = false, lastAccess = tick() }
	touchCacheEntry(part)
	evictOldestEntries()
	return nil
end

--------------------------------------------------------------------------------
-- Cache invalidation: remove entries when parts are removed from EuropeMap
--------------------------------------------------------------------------------
local descRemovingConn
local function setupCacheInvalidation()
	if not EuropeMap then return end
	descRemovingConn = EuropeMap.DescendantRemoving:Connect(function(desc)
		if desc and desc:IsA("BasePart") then
			if countryModelCache[desc] ~= nil then
				countryModelCache[desc] = nil
			end
			-- remove from access order
			for i = #cacheAccessOrder, 1, -1 do
				if cacheAccessOrder[i] == desc then
					table.remove(cacheAccessOrder, i)
					break
				end
			end
		end
	end)
end

--------------------------------------------------------------------------------
-- Visual control helpers (handles both Highlight and SelectionBox)
--------------------------------------------------------------------------------
local function disableCursorVisuals()
	if not Cursor then return end
	if Cursor:IsA("Highlight") then
		-- Ensure parent highlight does not silently highlight parent when adornee is nil
		Cursor.Adornee = nil
		Cursor.Enabled = false
	elseif Cursor:IsA("SelectionBox") then
		Cursor.Adornee = nil
		Cursor.Visible = false
	else
		-- fallback: try to nil adornee
		pcall(function() Cursor.Adornee = nil end)
	end
end

local function enableCursorVisuals(targetPart)
	if not Cursor then return end
	Cursor.Adornee = targetPart
	if Cursor:IsA("Highlight") then
		Cursor.Enabled = true
	elseif Cursor:IsA("SelectionBox") then
		Cursor.Visible = true
	end
end

--------------------------------------------------------------------------------
-- Main render loop
--------------------------------------------------------------------------------
local renderConn
local lastTarget = nil
local lastResult = nil -- for debug printing reduction

local function onRenderStepped()
	local target = Mouse.Target

	-- fast path: unchanged
	if target == lastTarget then return end
	lastTarget = target

	if target and target:IsA("BasePart") then
		local countryModel = getCountryModel(target)

		if countryModel then
			-- enable visuals on the exact hovered part (avoids whole-model highlight)
			enableCursorVisuals(target)

			if DEBUG_HOVER and lastResult ~= countryModel then
				print("✅ HIT:", countryModel.Name, "part:", target.Name)
				lastResult = countryModel
			end
		else
			-- nothing relevant, turn off visuals
			disableCursorVisuals()
			if DEBUG_HOVER and lastResult ~= "void" then
				-- optional debug: print("❌ IGNORED: " .. (target and target.Name or "nil"))
				lastResult = "void"
			end
		end
	else
		-- sky / no target
		disableCursorVisuals()
		lastResult = "nil"
	end
end

--------------------------------------------------------------------------------
-- Cleanup: disconnect everything & destroy the cloned cursor
--------------------------------------------------------------------------------
local function cleanup()
	-- Disconnect render
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	-- DescendantRemoving
	if descRemovingConn then
		descRemovingConn:Disconnect()
		descRemovingConn = nil
	end
	-- Clear cache tables
	countryModelCache = {}
	cacheAccessOrder = {}

	-- Destroy cursor clone safely
	if Cursor and Cursor.Parent then
		pcall(function() Cursor:Destroy() end)
	end
	Cursor = nil
end

--------------------------------------------------------------------------------
-- Setup connections & start
--------------------------------------------------------------------------------
script.Destroying:Connect(cleanup)
-- If the player is removed (server-side), also cleanup locally
local playerRemConn
playerRemConn = Players.PlayerRemoving:Connect(function(removedPlayer)
	if removedPlayer == Player then
		cleanup()
		if playerRemConn then playerRemConn:Disconnect() end
	end
end)

setupCacheInvalidation()
renderConn = RunService.RenderStepped:Connect(onRenderStepped)

if DEBUG_HOVER then print("[TileCursor] Initialized. DEBUG_HOVER =", DEBUG_HOVER) end
