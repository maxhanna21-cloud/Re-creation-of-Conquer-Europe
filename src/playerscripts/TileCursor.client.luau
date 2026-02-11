-- TileCursor LocalScript (StarterPlayerScripts) - FIXED v5
-- FIX #3: Proper cleanup of RenderStepped connection to prevent memory leaks
-- FIX #4: Only highlight actual country tiles (parts inside EuropeMap)
-- FIX #5: Exclude parts directly under EuropeMap (not inside country models)
-- FIX #6: Added caching for country model lookups to improve performance
-- FIX #7: Improved cache eviction - uses LRU-like approach, clears oldest half instead of all

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Player = Players.LocalPlayer
local Mouse = Player:GetMouse()

local Cursor = ReplicatedStorage:WaitForChild("TileCursor", 10)
Cursor.Parent = workspace

-- Get reference to the EuropeMap
local EuropeMap = Workspace:WaitForChild("EuropeMap", 10)

-- Store the connection so we can disconnect it later
local renderConnection = nil

-- FIX #7: Improved cache structure with access tracking for LRU eviction
-- Each entry: { countryModel = Model or false, lastAccess = tick() }
local countryModelCache = {}

-- FIX #7: Use ordered list to track access order for LRU eviction
local cacheAccessOrder = {} -- Array of BasePart references in order of access

local CACHE_MAX_SIZE = 500
local CACHE_EVICT_COUNT = 250 -- Evict half when full

-- FIX #7: Update access order for LRU tracking
local function touchCacheEntry(part)
	-- Remove from current position if exists
	for i, cachedPart in ipairs(cacheAccessOrder) do
		if cachedPart == part then
			table.remove(cacheAccessOrder, i)
			break
		end
	end
	-- Add to end (most recently accessed)
	table.insert(cacheAccessOrder, part)
end

-- FIX #7: Evict oldest entries when cache is full
local function evictOldestEntries()
	if #cacheAccessOrder <= CACHE_MAX_SIZE then
		return
	end

	-- Remove the oldest CACHE_EVICT_COUNT entries
	local toRemove = math.min(CACHE_EVICT_COUNT, #cacheAccessOrder - CACHE_MAX_SIZE + CACHE_EVICT_COUNT)

	for i = 1, toRemove do
		local oldPart = cacheAccessOrder[1]
		if oldPart then
			countryModelCache[oldPart] = nil
			table.remove(cacheAccessOrder, 1)
		end
	end
end

-- Helper function to get the country model a part belongs to
-- Returns nil if the part is not inside a valid country model
-- FIX #7: Now uses improved caching with LRU eviction
local function getCountryModel(part)
	-- Check cache first
	local cached = countryModelCache[part]
	if cached ~= nil then
		-- Update access order for LRU
		touchCacheEntry(part)
		-- cached.countryModel can be false (not a country tile) or a Model
		return cached.countryModel or nil
	end

	-- FIX #5: If part is directly under EuropeMap, it's not a country tile
	if part.Parent == EuropeMap then
		countryModelCache[part] = { countryModel = false, lastAccess = tick() }
		touchCacheEntry(part)
		evictOldestEntries()
		return nil
	end

	-- Walk up the hierarchy to find the country model
	local current = part.Parent
	while current and current ~= EuropeMap and current ~= Workspace do
		if current.Parent == EuropeMap then
			-- Found the country model (direct child of EuropeMap)
			countryModelCache[part] = { countryModel = current, lastAccess = tick() }
			touchCacheEntry(part)
			evictOldestEntries()
			return current
		end
		current = current.Parent
	end

	-- Not a country tile
	countryModelCache[part] = { countryModel = false, lastAccess = tick() }
	touchCacheEntry(part)
	evictOldestEntries()
	return nil
end

-- FIX #7: Invalidate cache when parts are added/removed from EuropeMap
local function setupCacheInvalidation()
	-- Clear specific entries when descendants are removed
	EuropeMap.DescendantRemoving:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			if countryModelCache[descendant] ~= nil then
				countryModelCache[descendant] = nil
				-- Also remove from access order
				for i, part in ipairs(cacheAccessOrder) do
					if part == descendant then
						table.remove(cacheAccessOrder, i)
						break
					end
				end
			end
		end
	end)

	-- Note: We don't need to handle DescendantAdded because
	-- new parts will just get cached on first access
end

local function onRenderStepped()
	local target = Mouse.Target

	-- 1. Check if the mouse is hovering over a BasePart
	if target and target:IsA("BasePart") then
		-- 2. Try to get the country model this part belongs to (cached)
		local countryModel = getCountryModel(target)

		-- 3. Only highlight if we found a valid country model
		if countryModel then
			Cursor.Adornee = target
		else
			Cursor.Adornee = nil
		end
	else
		Cursor.Adornee = nil
	end
end

-- Setup cache invalidation
setupCacheInvalidation()

-- Start the render connection
renderConnection = RunService.RenderStepped:Connect(onRenderStepped)

-- Clean up when the script is destroyed
script.Destroying:Connect(function()
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
	if Cursor then
		Cursor.Adornee = nil
	end
	-- Clear cache
	countryModelCache = {}
	cacheAccessOrder = {}
end)

-- Also clean up when player is removed
Player.AncestryChanged:Connect(function(_, parent)
	if not parent then
		if renderConnection then
			renderConnection:Disconnect()
			renderConnection = nil
		end
		-- Clear cache
		countryModelCache = {}
		cacheAccessOrder = {}
	end
end)