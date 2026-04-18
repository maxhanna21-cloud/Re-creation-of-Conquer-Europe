-- TileOwnershipManager (ModuleScript in ServerScriptService) - FIXED v3
-- FIX v2: Capital capture guard
-- FIX v3: Occupation stored by COUNTRY (not player) - persists when players leave
--         Occupied territory counts as valid tile for the occupying country

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local TileOwnershipManager = {}

-- Lazy-load dependencies
local ServerState = nil
local TileManager = nil
local TileAdjacencyManager = nil
local Combat = nil
local DiplomacyManager = nil

local function getDependencies()
	if not ServerState then
		ServerState = require(game.ServerScriptService:WaitForChild("ServerState", 10))
	end
	if not TileManager then
		TileManager = require(game.ServerScriptService:WaitForChild("TileManager", 10))
	end
	if not TileAdjacencyManager then
		TileAdjacencyManager = require(game.ServerScriptService:WaitForChild("TileAdjacencyManager", 10))
	end
	if not Combat then
		Combat = require(game.ServerScriptService:WaitForChild("NPCCombatSystem", 10))
	end
	if not DiplomacyManager then
		DiplomacyManager = require(game.ServerScriptService:WaitForChild("DiplomacyManager", 10))
	end
end

-- Configuration
local DEBUG = true
local EUROPE_MAP = Workspace:WaitForChild("EuropeMap", 10)

-- Store original tile colors
local OriginalColors = {}

-- FIX v3: Track occupied territories by COUNTRY name (persists when player leaves)
-- OccupiedTerritories[tilePart] = { occupyingCountry = "France", originalCountry = "Germany", originalColor = Color3 }
local OccupiedTerritories = {}

-- Store country colors
local CountryColors = {}

-- Capital capture guard
local capitalsBeingCaptured = {}

---------------------------------------------------
-- Initialization
---------------------------------------------------

local function scanCountryColors()
	for _, countryModel in ipairs(EUROPE_MAP:GetChildren()) do
		if countryModel:IsA("Model") then
			local countryName = countryModel.Name

			for _, part in ipairs(countryModel:GetDescendants()) do
				if part:IsA("BasePart") then
					CountryColors[countryName] = part.Color
					OriginalColors[part] = part.Color
					break
				end
			end

			for _, part in ipairs(countryModel:GetDescendants()) do
				if part:IsA("BasePart") then
					OriginalColors[part] = part.Color
				end
			end
		end
	end

	print("[TileOwnershipManager] Scanned country colors")
end

---------------------------------------------------
-- Color Management
---------------------------------------------------

function TileOwnershipManager.getCountryColor(countryName)
	return CountryColors[countryName]
end

function TileOwnershipManager.getPlayerColor(player)
	getDependencies()
	local playerCountry = TileManager.getPlayerCountry(player)
	if playerCountry then
		return CountryColors[playerCountry]
	end
	return nil
end

function TileOwnershipManager.getOriginalColor(tilePart)
	return OriginalColors[tilePart]
end

---------------------------------------------------
-- FIX v3: Country-based Occupation System
---------------------------------------------------

-- Check if a tile is occupied by a specific COUNTRY
function TileOwnershipManager.isOccupiedByCountry(tilePart, countryName)
	local data = OccupiedTerritories[tilePart]
	return data and data.occupyingCountry == countryName
end

-- Check if a tile is occupied by a specific PLAYER's country
function TileOwnershipManager.isOccupiedBy(tilePart, player)
	getDependencies()
	if not player then return false end

	local playerCountry = TileManager.getPlayerCountry(player)
	if not playerCountry then return false end

	return TileOwnershipManager.isOccupiedByCountry(tilePart, playerCountry)
end

-- Check if a tile is occupied by anyone
function TileOwnershipManager.isOccupied(tilePart)
	return OccupiedTerritories[tilePart] ~= nil
end

-- Get which COUNTRY occupies a tile
function TileOwnershipManager.getOccupyingCountry(tilePart)
	local data = OccupiedTerritories[tilePart]
	return data and data.occupyingCountry
end

-- Get the original country of an occupied tile
function TileOwnershipManager.getOriginalCountry(tilePart)
	getDependencies()
	local data = OccupiedTerritories[tilePart]
	if data then
		return data.originalCountry
	end
	return TileAdjacencyManager.getTileCountry(tilePart)
end

-- FIX v3: Check if tile belongs to a country (own territory OR occupied by them)
function TileOwnershipManager.tileEffectivelyBelongsTo(tilePart, countryName)
	getDependencies()

	if not tilePart or not countryName then return false end

	-- Check if it's their home territory
	local tileCountry = TileAdjacencyManager.getTileCountry(tilePart)
	if tileCountry == countryName then
		return true
	end

	-- Check if they've occupied it
	return TileOwnershipManager.isOccupiedByCountry(tilePart, countryName)
end

-- FIX v3: Check if tile belongs to player's country
function TileOwnershipManager.tileBelongsToPlayer(tilePart, player)
	getDependencies()
	if not player then return false end

	local playerCountry = TileManager.getPlayerCountry(player)
	if not playerCountry then return false end

	return TileOwnershipManager.tileEffectivelyBelongsTo(tilePart, playerCountry)
end

-- FIX v3: Capture a tile (store by country, not player)
function TileOwnershipManager.captureTile(tilePart, player)
	getDependencies()

	if not tilePart or not player then return false end

	local originalCountry = TileAdjacencyManager.getTileCountry(tilePart)
	local playerCountry = TileManager.getPlayerCountry(player)

	if not playerCountry then
		warn("[TileOwnership] Player has no country")
		return false
	end

	-- Don't capture your own tiles
	if originalCountry == playerCountry then
		return false
	end

	-- Don't re-capture already occupied tiles by same country
	if TileOwnershipManager.isOccupiedByCountry(tilePart, playerCountry) then
		return false
	end

	-- Get occupying country's color
	local occupyingColor = CountryColors[playerCountry]

	-- FIX: Validate occupyingColor exists, fallback to OriginalColors sampling
	if not occupyingColor then
		warn(string.format("[TileOwnership] CountryColors[%s] is nil in captureTile, sampling from OriginalColors", playerCountry))
		local playerCountryModel = EUROPE_MAP:FindFirstChild(playerCountry)
		if playerCountryModel then
			-- Find a tile in the player's country Model and use its original color
			for _, part in ipairs(playerCountryModel:GetDescendants()) do
				if part:IsA("BasePart") and OriginalColors[part] then
					occupyingColor = OriginalColors[part]
					CountryColors[playerCountry] = occupyingColor  -- Update cache
					break
				end
			end
		end

		if not occupyingColor then
			warn(string.format("[TileOwnership] Could not determine color for %s in captureTile, using default", playerCountry))
			occupyingColor = Color3.fromRGB(100, 100, 100)  -- Fallback grey
		end
	end

	-- Preserve original data if tile is already occupied by another country
	-- This ensures peace treaties revert to the true original owner's color
	local existingOccupation = OccupiedTerritories[tilePart]
	local storedOriginalCountry, storedOriginalColor

	if existingOccupation then
		storedOriginalCountry = existingOccupation.originalCountry
		storedOriginalColor = existingOccupation.originalColor
	else
		storedOriginalCountry = originalCountry
		storedOriginalColor = OriginalColors[tilePart] or tilePart.Color
	end

	OccupiedTerritories[tilePart] = {
		occupyingCountry = playerCountry,
		originalCountry = storedOriginalCountry,
		originalColor = storedOriginalColor
	}

	-- Change tile color
	tilePart.Color = occupyingColor

	if DEBUG then
		print("[TileOwnership] " .. playerCountry .. " captured tile in " .. originalCountry)
	end

	-- Fire event to notify clients
	local TileCapturedEvent = ReplicatedStorage:FindFirstChild("TileCapturedEvent")
	if TileCapturedEvent then
		TileCapturedEvent:FireAllClients(tilePart, player.Name, playerCountry)
	end

	return true
end

-- Release a captured tile (revert color)
function TileOwnershipManager.releaseTile(tilePart)
	local data = OccupiedTerritories[tilePart]
	if not data then return false end

	-- Revert color
	tilePart.Color = data.originalColor

	-- Remove from tracking
	OccupiedTerritories[tilePart] = nil

	if DEBUG then
		print("[TileOwnership] Released tile back to " .. data.originalCountry)
	end

	return true
end

-- Reclaim a tile that was occupied by an enemy back to its original owner
function TileOwnershipManager.reclaimTile(tilePart, player)
	getDependencies()

	if not tilePart or not player then return false end

	local data = OccupiedTerritories[tilePart]
	if not data then return false end

	local playerCountry = TileManager.getPlayerCountry(player)
	if not playerCountry then return false end

	-- Only reclaim if the tile's original country matches the player's country
	if data.originalCountry ~= playerCountry then
		return false
	end

	-- Revert tile color to the original color
	tilePart.Color = data.originalColor

	local occupyingCountry = data.occupyingCountry

	-- Remove from occupation tracking
	OccupiedTerritories[tilePart] = nil

	if DEBUG then
		print("[TileOwnership] " .. playerCountry .. " reclaimed tile from " .. occupyingCountry)
	end

	-- Notify the reclaiming player
	--local GlobalNotificationEvent = ReplicatedStorage:FindFirstChild("GlobalNotificationEvent")
	--if GlobalNotificationEvent then
		--GlobalNotificationEvent:FireClient(player, "Territory reclaimed from " .. occupyingCountry .. "!", Color3.fromRGB(100, 255, 100))
	--end

	-- Fire tile captured event for UI updates
	local TileCapturedEvent = ReplicatedStorage:FindFirstChild("TileCapturedEvent")
	if TileCapturedEvent then
		TileCapturedEvent:FireAllClients(tilePart, player.Name, playerCountry)
	end

	return true
end

-- Release all tiles occupied by a specific COUNTRY (used in peace treaties)
function TileOwnershipManager.releaseCountryOccupiedTiles(countryName)
	local releasedCount = 0

	-- FIX: Collect keys first to avoid modifying table during pairs() iteration
	local tilesToRelease = {}
	for tilePart, data in pairs(OccupiedTerritories) do
		if data.occupyingCountry == countryName then
			table.insert(tilesToRelease, tilePart)
		end
	end

	-- Now iterate over the collected keys to release tiles
	for _, tilePart in ipairs(tilesToRelease) do
		local data = OccupiedTerritories[tilePart]
		if data and tilePart and tilePart.Parent then
			tilePart.Color = data.originalColor
		end
		OccupiedTerritories[tilePart] = nil
		releasedCount = releasedCount + 1
	end

	if DEBUG and releasedCount > 0 then
		print("[TileOwnership] Released " .. releasedCount .. " tiles from " .. countryName)
	end

	return releasedCount
end

-- Get all tiles occupied by a specific COUNTRY
function TileOwnershipManager.getCountryOccupiedTiles(countryName)
	local tiles = {}
	for tilePart, data in pairs(OccupiedTerritories) do
		if data.occupyingCountry == countryName then
			table.insert(tiles, tilePart)
		end
	end
	return tiles
end

-- Get count of tiles occupied by a country
function TileOwnershipManager.getCountryOccupiedCount(countryName)
	local count = 0
	for _, data in pairs(OccupiedTerritories) do
		if data.occupyingCountry == countryName then
			count = count + 1
		end
	end
	return count
end

-- Annex occupied tiles: convert occupied territory to core territory
-- Used when signing peace - occupied tiles become permanent part of the occupying country
function TileOwnershipManager.annexOccupiedTiles(countryName)
	local annexedCount = 0

	-- Collect tiles to annex
	local tilesToAnnex = {}
	for tilePart, data in pairs(OccupiedTerritories) do
		if data.occupyingCountry == countryName then
			table.insert(tilesToAnnex, {tile = tilePart, data = data})
		end
	end

	-- Convert each occupied tile to core territory
	for _, entry in ipairs(tilesToAnnex) do
		local tilePart = entry.tile
		local data = entry.data

		if tilePart and tilePart.Parent then
			-- Change the tile's parent to the occupying country's model
			local occupyingCountryModel = EUROPE_MAP:FindFirstChild(countryName)
			if occupyingCountryModel then
				tilePart.Parent = occupyingCountryModel
				-- Keep the current color (already the occupying country's color)
				-- Remove from occupied territories table
				OccupiedTerritories[tilePart] = nil
				annexedCount = annexedCount + 1
			end
		end
	end

	if DEBUG and annexedCount > 0 then
		print("[TileOwnership] Annexed " .. annexedCount .. " tiles to " .. countryName)
	end

	return annexedCount
end

-- Legacy: Get tiles occupied by player (uses their country)
function TileOwnershipManager.getPlayerOccupiedTiles(player)
	getDependencies()
	local playerCountry = TileManager.getPlayerCountry(player)
	if not playerCountry then return {} end
	return TileOwnershipManager.getCountryOccupiedTiles(playerCountry)
end

-- Legacy: Get count for player
function TileOwnershipManager.getOccupiedTileCount(player)
	getDependencies()
	local playerCountry = TileManager.getPlayerCountry(player)
	if not playerCountry then return 0 end
	return TileOwnershipManager.getCountryOccupiedCount(playerCountry)
end

---------------------------------------------------
-- Capital Capture & Country Takeover
---------------------------------------------------

function TileOwnershipManager.isCapitalBeingCaptured(countryName)
	return capitalsBeingCaptured[countryName] == true
end

function TileOwnershipManager.captureCapital(losingCountryName, winningPlayer)
	getDependencies()

	if not losingCountryName or not winningPlayer then return false end

	if capitalsBeingCaptured[losingCountryName] then
		if DEBUG then
			print("[TileOwnership] Capital capture already in progress for " .. losingCountryName)
		end
		return false
	end

	-- FIX v4: Check if the country is already conquered
	local CountryOwners = ServerState.getCountryOwners()
	local currentOwner = CountryOwners[losingCountryName]
	if type(currentOwner) == "string" and currentOwner:find("Conquered_") then
		if DEBUG then
			print("[TileOwnership] Cannot capture " .. losingCountryName .. " - already conquered by " .. currentOwner)
		end
		return false
	end

	capitalsBeingCaptured[losingCountryName] = true

	local losingPlayer = currentOwner
	local winningCountry = TileManager.getPlayerCountry(winningPlayer)

	print("[TileOwnership] CAPITAL CAPTURED! " .. winningPlayer.Name .. " (" .. winningCountry .. ") conquered " .. losingCountryName)

	local GlobalNotificationEvent = ReplicatedStorage:FindFirstChild("GlobalNotificationEvent")
	if GlobalNotificationEvent then
		local msg = "👑 CONQUEST! " .. winningCountry .. " has conquered " .. losingCountryName .. "!"
		GlobalNotificationEvent:FireAllClients(msg, Color3.fromRGB(255, 215, 0))
	end

	TileOwnershipManager.performCountryTakeover(losingCountryName, winningPlayer, losingPlayer)

	-- Clear the guard after takeover is fully complete (not on a timer)
	capitalsBeingCaptured[losingCountryName] = nil

	return true
end

function TileOwnershipManager.performCountryTakeover(losingCountryName, winningPlayer, losingPlayer)
	getDependencies()

	local winningCountry = TileManager.getPlayerCountry(winningPlayer)
	local winningColor = CountryColors[winningCountry]

	-- FIX: Validate winningColor exists, fallback to OriginalColors sampling
	if not winningColor then
		warn(string.format("[TileOwnership] CountryColors[%s] is nil, sampling from OriginalColors", winningCountry))
		local winningCountryModel = EUROPE_MAP:FindFirstChild(winningCountry)
		if winningCountryModel then
			-- Find a tile in the winning country's Model and use its original color
			for _, part in ipairs(winningCountryModel:GetDescendants()) do
				if part:IsA("BasePart") and OriginalColors[part] then
					winningColor = OriginalColors[part]
					CountryColors[winningCountry] = winningColor  -- Update cache
					break
				end
			end
		end

		if not winningColor then
			warn(string.format("[TileOwnership] Could not determine color for %s, using default", winningCountry))
			winningColor = Color3.fromRGB(100, 100, 100)  -- Fallback grey
		end
	end

	-- 1. TRANSFER ALL TILES (change colors permanently)
	local countryModel = EUROPE_MAP:FindFirstChild(losingCountryName)
	if countryModel then
		for _, part in ipairs(countryModel:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Color = winningColor
				-- OriginalColors is immutable - do not modify during conquest

				-- CRITICAL: ALL tiles in the losing country must be added/updated in OccupiedTerritories
				-- If we set them to nil, they revert to their immutable Parent (losing country) and self-liberate
				local occupationData = OccupiedTerritories[part]
				if occupationData then
					-- This tile was already occupied - update the occupier to the winner
					-- and preserve original country for future transfers/peace treaties
					OccupiedTerritories[part] = {
						occupyingCountry = winningCountry,
						originalCountry = occupationData.originalCountry,
						originalColor = occupationData.originalColor
					}
				else
					-- This tile was never occupied (pure losing country core territory)
					-- Add it to OccupiedTerritories so the winner actually owns it
					OccupiedTerritories[part] = {
						occupyingCountry = winningCountry,
						originalCountry = losingCountryName,
						originalColor = OriginalColors[part] or part.Color
					}
				end

				-- FIX: Mark conquered capital tiles with attributes (defense-in-depth)
				-- Don't rename - attributes are metadata, renaming can break other systems
				if part.Name == "Capital" then
					part:SetAttribute("FormerCapitalOf", losingCountryName)
					part:SetAttribute("ConqueredBy", winningCountry)
				end
			end
		end
	end

	-- Transfer any tiles occupied by THIRD PARTIES in the losing country's territory to the winner
	-- (Skip entries already owned by winner — Phase 1 just created those)
	local occupiedTilesToRelease = {}
	for tilePart, data in pairs(OccupiedTerritories) do
		if data.originalCountry == losingCountryName and data.occupyingCountry ~= winningCountry then
			table.insert(occupiedTilesToRelease, tilePart)
		end
	end

	for _, tilePart in ipairs(occupiedTilesToRelease) do
		if tilePart and tilePart.Parent then
			tilePart.Color = winningColor
		end
		local existingData = OccupiedTerritories[tilePart]
		OccupiedTerritories[tilePart] = {
			occupyingCountry = winningCountry,
			originalCountry = losingCountryName,
			originalColor = existingData and existingData.originalColor
				or OriginalColors[tilePart] or tilePart.Color
		}
	end

	-- Recover orphaned tiles from countries the loser had previously conquered
	-- (Previous conquests may have lost their OccupiedTerritories entries)
	local CountryOwnersSnapshot = ServerState.getCountryOwners()
	local function collectConqueredCountries(countryName, collected)
		collected = collected or {}
		for cName, owner in pairs(CountryOwnersSnapshot) do
			if type(owner) == "string" and owner == "Conquered_" .. countryName then
				if not collected[cName] then
					collected[cName] = true
					collectConqueredCountries(cName, collected)
				end
			end
		end
		return collected
	end

	local conqueredByLoser = collectConqueredCountries(losingCountryName)
	for conqueredName, _ in pairs(conqueredByLoser) do
		local conqueredModel = EUROPE_MAP:FindFirstChild(conqueredName)
		if conqueredModel then
			for _, part in ipairs(conqueredModel:GetDescendants()) do
				if part:IsA("BasePart") and OriginalColors[part] then
					local existingData = OccupiedTerritories[part]
					if not existingData then
						OccupiedTerritories[part] = {
							occupyingCountry = winningCountry,
							originalCountry = conqueredName,
							originalColor = OriginalColors[part]
						}
						part.Color = winningColor
					end
				end
			end
		end
	end

	-- FIX (Bug 2): Transfer ownership of occupied territories to the conquering country
	-- CRITICAL: Do NOT re-parent tiles (keep geography immutable, only change ownership)
	-- When conquering a country, all territories they controlled should transfer to the winner

	-- Phase 1: Collect tiles to transfer (don't mutate OccupiedTerritories while iterating)
	local tilesToTransfer = {}
	for tilePart, data in pairs(OccupiedTerritories) do
		if data.occupyingCountry == losingCountryName then
			table.insert(tilesToTransfer, {tilePart = tilePart, data = data})
		end
	end

	-- Phase 2: Transfer ownership
	for _, entry in ipairs(tilesToTransfer) do
		local tilePart = entry.tilePart
		local data = entry.data

		if tilePart and tilePart.Parent then
			-- Transfer ownership to the winning country
			-- Update the occupation record: winner now occupies this tile (from its original owner)
			OccupiedTerritories[tilePart] = {
				occupyingCountry = winningCountry,
				originalCountry = data.originalCountry,  -- Preserve original geographic owner
				originalColor = data.originalColor       -- Preserve original color
			}

			-- Recolor to winner's color
			if not winningColor then
				warn(string.format("[TileOwnership] winningColor is nil when transferring %s tile, skipping color update", tilePart.Name))
			else
				tilePart.Color = winningColor
			end

			if DEBUG then
				print(string.format("[TileOwnership] Annexed %s's occupied tile from %s to %s (tile stays in %s's Model)",
					losingCountryName, data.originalCountry, winningCountry, data.originalCountry))
			end
		end
	end

	-- Do NOT call releaseCountryOccupiedTiles() - that's for peace treaties, not conquests
	-- OLD (Bug 2): TileOwnershipManager.releaseCountryOccupiedTiles(losingCountryName)

	-- 2. TRANSFER RESOURCES
	if losingPlayer and typeof(losingPlayer) == "Instance" and losingPlayer:IsA("Player") and losingPlayer.Parent then
		local loserStats = losingPlayer:FindFirstChild("leaderstats")
		local winnerStats = winningPlayer:FindFirstChild("leaderstats")

		-- FIX: Added proper nil checks for loserStats and winnerStats
		if loserStats and winnerStats then
			local loserCoins = loserStats:FindFirstChild("Coins")
			local winnerCoins = winnerStats:FindFirstChild("Coins")
			if loserCoins and winnerCoins then
				winnerCoins.Value = winnerCoins.Value + loserCoins.Value
				loserCoins.Value = 0
			end

			local loserManpower = loserStats:FindFirstChild("Manpower")
			local winnerManpower = winnerStats:FindFirstChild("Manpower")
			if loserManpower and winnerManpower then
				winnerManpower.Value = winnerManpower.Value + loserManpower.Value
				loserManpower.Value = 0
			end
		elseif DEBUG then
			warn("[TileOwnership] Could not transfer resources - leaderstats missing")
		end
	else
		-- Country was unowned - transfer from ServerState
		local countryCoins = ServerState.getCountryCoins(losingCountryName)
		local countryManpower = ServerState.getCountryManpower(losingCountryName)

		local winnerStats = winningPlayer:FindFirstChild("leaderstats")
		if winnerStats then
			local winnerCoins = winnerStats:FindFirstChild("Coins")
			local winnerManpower = winnerStats:FindFirstChild("Manpower")

			if winnerCoins then
				winnerCoins.Value = winnerCoins.Value + countryCoins
			end
			if winnerManpower then
				winnerManpower.Value = winnerManpower.Value + countryManpower
			end
		end

		ServerState.setCountryCoins(losingCountryName, 0)
		ServerState.setCountryManpower(losingCountryName, 0)
	end

	-- 3. TRANSFER NPCs
	for _, child in ipairs(Workspace:GetChildren()) do
		if child:IsA("Model") and child:FindFirstChild("Humanoid") and child:FindFirstChild("NPCOwner") then
			local npcCountry = child:GetAttribute("Country")
			if npcCountry == losingCountryName then
				local ownerValue = child:FindFirstChild("NPCOwner")
				if ownerValue then
					ownerValue.Value = winningPlayer
				end
				child:SetAttribute("Country", winningCountry)
				Combat.transferOwnership(child, winningPlayer)

				-- Recolor NPC to winning country's color
				if winningColor then
					for _, part in ipairs(child:GetDescendants()) do
						if part:IsA("BasePart") then
							part.Color = winningColor
						end
					end
				end

				if DEBUG then
					print("[TileOwnership] Transferred NPC " .. child.Name .. " to " .. winningPlayer.Name)
				end
			end
		end
	end

	-- 4. UPDATE COUNTRY OWNERSHIP
	local CountryOwners = ServerState.getCountryOwners()
	CountryOwners[losingCountryName] = "Conquered_" .. winningCountry
	ServerState.setCountryOwners(CountryOwners)

	-- FIX v4: Clear all wars involving the conquered country
	DiplomacyManager.clearAllWarsForCountry(losingCountryName)

	-- 5. HANDLE LOSING PLAYER
	if losingPlayer and typeof(losingPlayer) == "Instance" and losingPlayer:IsA("Player") and losingPlayer.Parent then
		local loserStats = losingPlayer:FindFirstChild("leaderstats")
		if loserStats then
			local countryStat = loserStats:FindFirstChild("Country")
			if countryStat then
				countryStat.Value = "Defeated"
			end
		end

		if losingPlayer.Character then
			local humanoid = losingPlayer.Character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.Health = 0
			end
		end

		local GlobalNotificationEvent = ReplicatedStorage:FindFirstChild("GlobalNotificationEvent")
		if GlobalNotificationEvent then
			GlobalNotificationEvent:FireClient(losingPlayer, "💀 Your capital has fallen! You have been defeated.", Color3.fromRGB(255, 0, 0))
		end

		TileManager.updatePlayerCountryCache(losingPlayer, nil)
	end

	-- DEBUG: Sanity check — detect tiles that should be owned but are missing OccupiedTerritories
	if DEBUG then
		local missingCount = 0
		local allCountriesToCheck = {losingCountryName}
		for cName, _ in pairs(conqueredByLoser) do
			table.insert(allCountriesToCheck, cName)
		end
		for _, cName in ipairs(allCountriesToCheck) do
			local cModel = EUROPE_MAP:FindFirstChild(cName)
			if cModel then
				for _, part in ipairs(cModel:GetDescendants()) do
					if part:IsA("BasePart") and OriginalColors[part] then
						if not OccupiedTerritories[part] then
							missingCount = missingCount + 1
						end
					end
				end
			end
		end
		if missingCount > 0 then
			warn(string.format("[TileOwnership] SANITY CHECK FAILED: %d tiles missing OccupiedTerritories after takeover of %s",
				missingCount, losingCountryName))
		end
	end

	print("[TileOwnership] Country takeover complete: " .. losingCountryName .. " -> " .. winningCountry)
end

---------------------------------------------------
-- Initialize
---------------------------------------------------

scanCountryColors()

-- FIX v3: Do NOT auto-release on player leave - territories persist!

print("[TileOwnershipManager] Initialization complete")

return TileOwnershipManager