-- TileOwnershipManager (ModuleScript in ServerScriptService)
-- Occupation stored by COUNTRY (not player) - persists when players leave
-- Capital capture guard + conquered state check
-- Single no-yield atomic ownership mutation path via state applicators

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
local CountryNPCRegistry = nil

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
	if not CountryNPCRegistry then
		CountryNPCRegistry = require(game.ServerScriptService:WaitForChild("CountryNPCRegistry", 10))
	end
end

-- Configuration
local DEBUG = false
local EUROPE_MAP = Workspace:WaitForChild("EuropeMap", 10)

-- Store original tile colors
local OriginalColors = {}

-- Track occupied territories by COUNTRY name (persists when player leaves)
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

	if DEBUG then print("[TileOwnershipManager] Scanned country colors") end
end

---------------------------------------------------
-- Private: Color Resolution
---------------------------------------------------

-- Resolves the display color for a country.
-- Checks CountryColors cache first, then falls back to sampling OriginalColors
-- from the country's map Model. Caches the result on success.
local function resolveCountryColor(countryName)
	local color = CountryColors[countryName]
	if color then return color end

	-- Fallback: sample from direct children of country model
	local countryModel = EUROPE_MAP:FindFirstChild(countryName)
	if countryModel then
		for _, child in ipairs(countryModel:GetChildren()) do
			if child:IsA("BasePart") and OriginalColors[child] then
				color = OriginalColors[child]
				CountryColors[countryName] = color
				return color
			end
		end
	end

	warn("[TileOwnership] resolveCountryColor: no color found for '" .. tostring(countryName) .. "'")
	return nil
end

---------------------------------------------------
-- Private: Low-Level State Helpers
-- These are NOT public entry points — they are atomic building blocks only.
-- Every write to visual, logical, and occupied state flows through exactly one
-- of the three high-level applicators below, which call these helpers together
-- with no yield between them.
---------------------------------------------------

-- Set tile color to the controlling country's color.
-- Returns true on success, false if color could not be resolved (logs a warning).
local function applyTileVisualOwner(tilePart, ownerCountryName)
	local color = resolveCountryColor(ownerCountryName)
	if not color then
		warn("[TileOwnership] applyTileVisualOwner: no color for '" .. tostring(ownerCountryName) .. "' on tile " .. tilePart.Name)
		return false
	end
	tilePart.Color = color
	return true
end

-- Restore the tile to its original (pre-capture) visual state.
local function applyTileOriginalVisual(tilePart, originalColor)
	if not originalColor then
		warn("[TileOwnership] applyTileOriginalVisual: originalColor is nil for tile " .. tilePart.Name)
		return
	end
	tilePart.Color = originalColor
end

-- Set or clear the OwnerCountry attribute.
-- Pass a non-empty string to assign; pass nil or "" to clear.
local function setTileLogicalOwner(tilePart, ownerCountryNameOrNil)
	if type(ownerCountryNameOrNil) == "string" and ownerCountryNameOrNil ~= "" then
		tilePart:SetAttribute("OwnerCountry", ownerCountryNameOrNil)
	else
		tilePart:SetAttribute("OwnerCountry", nil)
	end
end

-- Write the OccupiedTerritories record for a tile.
local function setOccupiedRecord(tilePart, occupyingCountry, originalCountry, originalColor)
	OccupiedTerritories[tilePart] = {
		occupyingCountry = occupyingCountry,
		originalCountry = originalCountry,
		originalColor = originalColor,
	}
end

-- Delete the OccupiedTerritories record for a tile.
local function clearOccupiedRecord(tilePart)
	OccupiedTerritories[tilePart] = nil
end

---------------------------------------------------
-- Private: High-Level State Applicators
-- These are the ONLY valid paths for changing tile ownership state.
-- All three writes (visual, logical, occupied record) happen synchronously
-- with no yield between them — this is the "atomic" guarantee.
---------------------------------------------------

-- Invariant A: Occupied but not annexed.
-- After this call:
--   OccupiedTerritories[tilePart] ~= nil
--   OwnerCountry == occupyingCountry
--   tilePart.Color == CountryColors[occupyingCountry]
-- Returns false if the occupying country has no resolvable color (no state written).
local function applyOccupiedState(tilePart, occupyingCountry, originalCountry, originalColor)
	if not applyTileVisualOwner(tilePart, occupyingCountry) then return false end
	setTileLogicalOwner(tilePart, occupyingCountry)
	setOccupiedRecord(tilePart, occupyingCountry, originalCountry, originalColor)
	return true
end

-- Invariant B: Annexed.
-- After this call:
--   OccupiedTerritories[tilePart] == nil
--   OwnerCountry == annexingCountry
--   tilePart.Color == CountryColors[annexingCountry]  (same color, tile was already colored for occupier)
-- Returns false if the annexing country has no resolvable color (no state written).
local function applyAnnexedState(tilePart, annexingCountry)
	if not applyTileVisualOwner(tilePart, annexingCountry) then return false end
	setTileLogicalOwner(tilePart, annexingCountry)
	clearOccupiedRecord(tilePart)
	return true
end

-- Invariant C/D: Reverted to geographic/original ownership.
-- After this call:
--   OccupiedTerritories[tilePart] == nil
--   OwnerCountry == nil
--   tilePart.Color == originalColor
local function applyOriginalState(tilePart, originalColor)
	applyTileOriginalVisual(tilePart, originalColor)
	setTileLogicalOwner(tilePart, nil)
	clearOccupiedRecord(tilePart)
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
-- Country-based Occupation System
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

-- Check if tile belongs to a country (own territory OR occupied by them)
function TileOwnershipManager.tileEffectivelyBelongsTo(tilePart, countryName)
	getDependencies()

	if not tilePart or not countryName then return false end

	-- Check explicit ownership attribute first (set on capture and annexation)
	-- This handles annexed tiles that stay in their original country Model
	local ownerAttr = tilePart:GetAttribute("OwnerCountry")
	if ownerAttr then
		return ownerAttr == countryName
	end

	-- Check if it's their home territory (no ownership attribute = never captured)
	local tileCountry = TileAdjacencyManager.getTileCountry(tilePart)
	if tileCountry == countryName then
		return true
	end

	-- Check if they've occupied it
	return TileOwnershipManager.isOccupiedByCountry(tilePart, countryName)
end

-- Check if tile belongs to player's country
function TileOwnershipManager.tileBelongsToPlayer(tilePart, player)
	getDependencies()
	if not player then return false end

	local playerCountry = TileManager.getPlayerCountry(player)
	if not playerCountry then return false end

	return TileOwnershipManager.tileEffectivelyBelongsTo(tilePart, playerCountry)
end

---------------------------------------------------
-- Public Mutation Functions
-- All tile state changes flow through the state applicators above.
---------------------------------------------------

-- Capture a tile (store by country, not player)
function TileOwnershipManager.captureTile(tilePart, player)
	getDependencies()

	if not tilePart or not player then return false end

	local geographicCountry = TileAdjacencyManager.getTileCountry(tilePart)
	local effectiveOwner = TileAdjacencyManager.getEffectiveOwner(tilePart)
	local playerCountry = TileManager.getPlayerCountry(player)

	if not playerCountry then
		warn("[TileOwnership] Player has no country")
		return false
	end

	-- Don't capture tiles already effectively owned by you
	if effectiveOwner == playerCountry then
		return false
	end

	-- RECLAIM: Tile is geographically ours but controlled by someone else (annexed).
	-- Restore to original geographic state (Invariant D).
	-- Must come BEFORE isOccupiedByCountry to avoid early-return on residual entries.
	if geographicCountry == playerCountry then
		local origColor = OriginalColors[tilePart]
		if not origColor then
			warn("[TileOwnership] captureTile reclaim: no original color for tile " .. tilePart.Name)
			return false
		end

		-- Invariant D: reclaimed original land relies on geography again.
		-- OwnerCountry = nil, no occupied record, original color restored.
		applyOriginalState(tilePart, origColor)

		if DEBUG then
			print("[TileOwnership] " .. playerCountry .. " reclaimed annexed tile (was owned by " .. tostring(effectiveOwner) .. ")")
		end

		-- Fire event AFTER all state writes are complete
		local TileCapturedEvent = ReplicatedStorage:FindFirstChild("TileCapturedEvent")
		if TileCapturedEvent then
			TileCapturedEvent:FireAllClients(tilePart, player.Name, playerCountry)
		end
		return true
	end

	-- Don't re-capture already occupied tiles by same country
	if TileOwnershipManager.isOccupiedByCountry(tilePart, playerCountry) then
		return false
	end

	-- Preserve original data if tile is already occupied by another country.
	-- This ensures peace treaties revert to the true original owner's color.
	local existingOccupation = OccupiedTerritories[tilePart]
	local storedOriginalCountry, storedOriginalColor

	if existingOccupation then
		storedOriginalCountry = existingOccupation.originalCountry
		storedOriginalColor = existingOccupation.originalColor
	else
		storedOriginalCountry = geographicCountry
		storedOriginalColor = OriginalColors[tilePart] or tilePart.Color
	end

	-- Invariant A: occupied state — all three writes happen together, no yield.
	if not applyOccupiedState(tilePart, playerCountry, storedOriginalCountry, storedOriginalColor) then
		-- applyOccupiedState already warned about missing color
		return false
	end

	if DEBUG then
		print("[TileOwnership] " .. playerCountry .. " captured tile in " .. (geographicCountry or "unknown"))
	end

	-- Fire event AFTER all state writes are complete
	local TileCapturedEvent = ReplicatedStorage:FindFirstChild("TileCapturedEvent")
	if TileCapturedEvent then
		TileCapturedEvent:FireAllClients(tilePart, player.Name, playerCountry)
	end

	return true
end

-- Release a captured tile (revert to geographic/original state)
function TileOwnershipManager.releaseTile(tilePart)
	local data = OccupiedTerritories[tilePart]
	if not data then return false end

	local originalCountry = data.originalCountry
	local originalColor = data.originalColor

	-- Invariant C: reverted to geographic owner — all three writes together, no yield.
	applyOriginalState(tilePart, originalColor)

	if DEBUG then
		print("[TileOwnership] Released tile back to " .. (originalCountry or "unknown"))
	end

	-- Fire event AFTER all state writes are complete.
	-- Notify clients so they cancel any in-flight tween and start one to the correct color.
	local TileCapturedEvent = ReplicatedStorage:FindFirstChild("TileCapturedEvent")
	if TileCapturedEvent and originalCountry then
		TileCapturedEvent:FireAllClients(tilePart, "", originalCountry)
	end

	return true
end

-- Reclaim a tile that was occupied by an enemy back to its original owner.
-- BUG FIX: Previous version omitted the OwnerCountry clear, leaving the attribute stale.
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

	local occupyingCountry = data.occupyingCountry
	local originalColor = data.originalColor

	-- Invariant D: reclaimed original land relies on geography again.
	-- BUG FIX: now explicitly clears OwnerCountry (was missing before).
	-- OwnerCountry = nil, no occupied record, original color restored.
	applyOriginalState(tilePart, originalColor)

	if DEBUG then
		print("[TileOwnership] " .. playerCountry .. " reclaimed tile from " .. occupyingCountry)
	end

	-- Fire tile captured event AFTER all state writes are complete
	local TileCapturedEvent = ReplicatedStorage:FindFirstChild("TileCapturedEvent")
	if TileCapturedEvent then
		TileCapturedEvent:FireAllClients(tilePart, player.Name, playerCountry)
	end

	return true
end

-- Release all tiles occupied by a specific COUNTRY (used in peace treaties).
-- BUG FIX: Previous version omitted the OwnerCountry clear on each released tile.
function TileOwnershipManager.releaseCountryOccupiedTiles(countryName)
	local releasedCount = 0

	-- FIX: Collect keys first to avoid modifying table during pairs() iteration
	local tilesToRelease = {}
	for tilePart, data in pairs(OccupiedTerritories) do
		if data.occupyingCountry == countryName then
			table.insert(tilesToRelease, { tilePart = tilePart, data = data })
		end
	end

	local TileCapturedEvent = ReplicatedStorage:FindFirstChild("TileCapturedEvent")

	for _, entry in ipairs(tilesToRelease) do
		local tilePart = entry.tilePart
		local data = entry.data

		if tilePart and tilePart.Parent then
			-- Invariant C: all three writes together, no yield.
			-- BUG FIX: now explicitly clears OwnerCountry (was missing before).
			applyOriginalState(tilePart, data.originalColor)
			-- Fire event AFTER state is fully applied
			if TileCapturedEvent and data.originalCountry then
				TileCapturedEvent:FireAllClients(tilePart, "", data.originalCountry)
			end
		else
			-- Part was destroyed — clear the orphaned record to prevent memory leak
			clearOccupiedRecord(tilePart)
		end
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

-- Annex occupied tiles: convert occupied territory to core territory.
-- Used when signing peace — occupied tiles become permanent part of the occupying country.
function TileOwnershipManager.annexOccupiedTiles(countryName)
	local annexedCount = 0

	-- Collect tiles to annex
	local tilesToAnnex = {}
	for tilePart, data in pairs(OccupiedTerritories) do
		if data.occupyingCountry == countryName then
			table.insert(tilesToAnnex, { tile = tilePart, data = data })
		end
	end

	local TileCapturedEvent = ReplicatedStorage:FindFirstChild("TileCapturedEvent")

	for _, entry in ipairs(tilesToAnnex) do
		local tilePart = entry.tile

		if tilePart and tilePart.Parent then
			-- Invariant B: annexed — no occupied record, OwnerCountry set, color re-confirmed.
			-- applyAnnexedState re-resolves the color (same as occupying color, effectively no-op visually).
			if applyAnnexedState(tilePart, countryName) then
				annexedCount = annexedCount + 1
				-- Fire event AFTER all state writes are complete
				if TileCapturedEvent then
					TileCapturedEvent:FireAllClients(tilePart, "", countryName)
				end
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

	-- Check if the country is already conquered
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

	if DEBUG then print("[TileOwnership] CAPITAL CAPTURED! " .. winningPlayer.Name .. " (" .. winningCountry .. ") conquered " .. losingCountryName) end

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

	-- Batched tile capture list — fire ONE RemoteEvent at the end instead of per-tile
	local capturedTilesBatch = {}

	-- 1. TRANSFER TILES in the loser's own country model.
	-- Uses cached TileParts from TileAdjacencyManager instead of expensive GetDescendants().
	-- For each tile: decide final ownership state, then apply visual + attribute + record together.
	local loserTileParts = TileAdjacencyManager.getCountryTileParts(losingCountryName)
	for _, part in ipairs(loserTileParts) do
		-- Mark conquered capital tiles with attributes (defense-in-depth)
		if part.Name == "Capital" then
			part:SetAttribute("FormerCapitalOf", losingCountryName)
			part:SetAttribute("ConqueredBy", winningCountry)
		end

		local occupationData = OccupiedTerritories[part]
		if occupationData then
			if occupationData.occupyingCountry ~= winningCountry
				and occupationData.occupyingCountry ~= losingCountryName then
				-- Third party occupies this tile — leave their color and ownership intact
				if DEBUG then
					print(string.format("[TileOwnership] Skipping %s (third-party: %s)",
						part.Name, occupationData.occupyingCountry))
				end
			else
				-- Loser or winner had it — transfer to winner (Invariant A: occupied state)
				if applyOccupiedState(part, winningCountry, occupationData.originalCountry, occupationData.originalColor) then
					table.insert(capturedTilesBatch, part)
				end
			end
		else
			-- Unoccupied core territory — winner takes it (Invariant A: occupied state).
			-- Capture origColor BEFORE applyOccupiedState changes part.Color.
			local origColor = OriginalColors[part] or part.Color
			if applyOccupiedState(part, winningCountry, losingCountryName, origColor) then
				table.insert(capturedTilesBatch, part)
			end
		end
	end

	-- Third-party occupied tiles remain with their current occupier.
	if DEBUG then
		local thirdPartyCount = 0
		for _, data in pairs(OccupiedTerritories) do
			if data.originalCountry == losingCountryName and data.occupyingCountry ~= winningCountry then
				thirdPartyCount = thirdPartyCount + 1
			end
		end
		if thirdPartyCount > 0 then
			print(string.format("[TileOwnership] %d tiles in %s remain with third-party occupiers (not transferred to %s)",
				thirdPartyCount, losingCountryName, winningCountry))
		end
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
		-- Use cached tile parts instead of GetDescendants()
		local conqueredTileParts = TileAdjacencyManager.getCountryTileParts(conqueredName)
		for _, part in ipairs(conqueredTileParts) do
			if OriginalColors[part] then
				local existingData = OccupiedTerritories[part]
				if not existingData then
					-- Orphaned tile — winner claims it (Invariant A)
					if applyOccupiedState(part, winningCountry, conqueredName, OriginalColors[part]) then
						table.insert(capturedTilesBatch, part)
					end
				end
			end
		end
	end

	-- FIX (Bug 2): Transfer ownership of ALL occupied territories belonging to the loser
	-- (tiles in other countries' models that the loser was occupying).
	-- Collect BEFORE mutating OccupiedTerritories to avoid iteration issues.
	local tilesToTransfer = {}
	for tilePart, data in pairs(OccupiedTerritories) do
		if data.occupyingCountry == losingCountryName then
			table.insert(tilesToTransfer, { tilePart = tilePart, data = data })
		end
	end

	for _, entry in ipairs(tilesToTransfer) do
		local tilePart = entry.tilePart
		local data = entry.data

		if tilePart and tilePart.Parent then
			-- Transfer to winner (Invariant A: occupied state)
			if applyOccupiedState(tilePart, winningCountry, data.originalCountry, data.originalColor) then
				table.insert(capturedTilesBatch, tilePart)
			end

			if DEBUG then
				print(string.format("[TileOwnership] Annexed %s's occupied tile from %s to %s (tile stays in %s's Model)",
					losingCountryName, data.originalCountry, winningCountry, data.originalCountry))
			end
		end
	end

	-- Fire ONE batched RemoteEvent for all captured tiles instead of per-tile spam
	if #capturedTilesBatch > 0 then
		local TileCapturedEvent = ReplicatedStorage:FindFirstChild("TileCapturedEvent")
		if TileCapturedEvent then
			TileCapturedEvent:FireAllClients(capturedTilesBatch, winningPlayer.Name, winningCountry)
		end
	end

	-- Do NOT call releaseCountryOccupiedTiles() — that's for peace treaties, not conquests

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
		-- Country was unowned — transfer from ServerState
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

	-- 3. DESTROY conquered country's NPCs (winner inherits income, not units)
	local npcsToDestroy = CountryNPCRegistry.getNPCs(losingCountryName)
	for _, npc in ipairs(npcsToDestroy) do
		local humanoid = npc:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Health = 0 -- triggers existing NPCSpawner cleanup pipeline
		end
	end
	if DEBUG then
		print("[TileOwnership] Destroyed " .. #npcsToDestroy .. " NPCs from conquered " .. losingCountryName)
	end

	-- 4. UPDATE COUNTRY OWNERSHIP
	local CountryOwners = ServerState.getCountryOwners()
	CountryOwners[losingCountryName] = "Conquered_" .. winningCountry
	ServerState.setCountryOwners(CountryOwners)

	-- Clear all diplomacy (wars, alliances, NAPs) involving the conquered country
	DiplomacyManager.clearAllDiplomacyForCountry(losingCountryName)

	-- 5. HANDLE LOSING PLAYER
	if losingPlayer and typeof(losingPlayer) == "Instance" and losingPlayer:IsA("Player") and losingPlayer.Parent then
		local loserStats = losingPlayer:FindFirstChild("leaderstats")
		if loserStats then
			local countryStat = loserStats:FindFirstChild("Country")
			if countryStat then
				-- Use "None" (not "Defeated") so the client CountrySelectionScreen
				-- re-opens on the next CharacterAdded. The defeat notification is
				-- already sent via GlobalNotificationEvent above.
				countryStat.Value = "None"
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
		local allCountriesToCheck = { losingCountryName }
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

	if DEBUG then print("[TileOwnership] Country takeover complete: " .. losingCountryName .. " -> " .. winningCountry) end
end

---------------------------------------------------
-- Initialize
---------------------------------------------------

scanCountryColors()

-- Do NOT auto-release on player leave - territories persist!

if DEBUG then print("[TileOwnershipManager] Initialization complete") end

return TileOwnershipManager
