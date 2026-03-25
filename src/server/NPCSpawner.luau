-- NPCSpawner
-- Shared NPC spawn logic used by NPCPurchaseHandler and CountryManager (starter NPCs).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")
local CollectionService = game:GetService("CollectionService")

local Combat = require(game.ServerScriptService:WaitForChild("NPCCombatSystem", 10))
local TileManager = require(game.ServerScriptService:WaitForChild("TileManager", 10))
local TileAdjacencyManager = require(game.ServerScriptService:WaitForChild("TileAdjacencyManager", 10))
local UnitManager = require(game.ServerScriptService:WaitForChild("UnitManager", 10))
local TileOwnershipManager = require(game.ServerScriptService:WaitForChild("TileOwnershipManager", 10))
local CountryNPCRegistry = require(game.ServerScriptService:WaitForChild("CountryNPCRegistry", 10))

local NPC_TAG = "RegisteredNPC"

-- =============================================
-- CONFIG
-- =============================================
-- Set to true to paint each NPC's body parts with their country's tile color.
-- Set to false to leave NPCs as the default template appearance.
local NPC_COUNTRY_COLORS = true

local NPCSpawner = {}

local function setNPCCollisionGroup(npcModel)
	for _, part in ipairs(npcModel:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CollisionGroup = "NPCs"
		end
	end
end

local function setNPCBodyColor(npcModel, countryName)
	local countryColor = TileOwnershipManager.getCountryColor(countryName)
	if not countryColor then return end
	for _, part in ipairs(npcModel:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Color = countryColor
		end
	end
end

-- Spawns an NPC for a country.
-- ownerPlayer: Player instance (player-owned) or nil (country-owned).
-- Returns the spawned npcModel, or nil on failure.
function NPCSpawner.spawnNPC(countryName, npcType, spawnPos, tileKey, ownerPlayer)
	local npcTemplate = ReplicatedStorage:FindFirstChild(npcType)
	if not npcTemplate then
		warn("[NPCSpawner] Template not found: " .. tostring(npcType))
		return nil
	end

	local npcClone = npcTemplate:Clone()
	setNPCCollisionGroup(npcClone)
	if NPC_COUNTRY_COLORS then
		setNPCBodyColor(npcClone, countryName)
	end

	local role = (npcType == "DefenderNPC") and "Defender" or "Attacker"

	-- Setup ownership
	local ownerVal = Instance.new("ObjectValue")
	ownerVal.Name = "NPCOwner"
	ownerVal.Value = ownerPlayer -- nil for country-owned
	ownerVal.Parent = npcClone

	npcClone.Name = npcType
	npcClone:PivotTo(CFrame.new(spawnPos))
	npcClone.Parent = workspace

	-- Resolve spawn tile part early so we can use TileId-authoritative occupancy API
	local spawnTilePart = TileAdjacencyManager.getTileFromKey(tileKey)

	-- Mark tile as occupied using TileId-authoritative path when tilePart is available
	if spawnTilePart then
		TileManager.occupyResolvedTile(countryName, spawnTilePart, npcClone)
	else
		-- Fallback: compatibility shim resolves internally (warns if tileKey cannot resolve)
		TileManager.occupyTile(countryName, tileKey, npcClone)
	end

	-- Store tile/country info for cleanup
	npcClone:SetAttribute("TileKey", tileKey)
	npcClone:SetAttribute("Country", countryName)
	-- Set CurrentTileId for reliable adjacency resolution (stable, unique tile identity)
	if spawnTilePart then
		local spawnTileId = TileAdjacencyManager.getTileId(spawnTilePart)
		if spawnTileId then
			npcClone:SetAttribute("CurrentTileId", spawnTileId)
		end
	end

	-- Tag for diagnostics
	CollectionService:AddTag(npcClone, NPC_TAG)

	-- Register with per-country index
	CountryNPCRegistry.register(countryName, npcClone)

	-- Mark country-owned NPCs as auto-retaliating (player-owned NPCs don't get this)
	if not ownerPlayer then
		npcClone:SetAttribute("AutoRetaliate", true)
	end

	-- Guarded cleanup: runs exactly once regardless of which event fires first
	local cleanedUp = false
	local function cleanup()
		if cleanedUp then return end
		cleanedUp = true

		-- Mark as dead so targeting/combat loops ignore this NPC
		npcClone:SetAttribute("Dead", true)

		-- Destroy ClickDetector so corpse can't be clicked regardless of future edits
		local head = npcClone:FindFirstChild("Head")
		if head then
			local cd = head:FindFirstChild("ClickDetector")
			if cd then cd:Destroy() end
		end

		-- Release tile occupancy and unregister from country registry
		-- Use the Country attribute directly for correctness after ownership transfers
		local key = npcClone:GetAttribute("TileKey")
		local country = npcClone:GetAttribute("Country")
		if key and country then
			TileManager.releaseTile(country, key)
		end
		if country then
			CountryNPCRegistry.unregister(country, npcClone)
		end

		-- Remove diagnostics tag
		CollectionService:RemoveTag(npcClone, NPC_TAG)

		-- Unregister from UnitManager if player-owned
		if ownerPlayer then
			UnitManager.deregisterUnit(ownerPlayer, npcClone)
		end

		-- Unregister from combat system (clears all target/threat tables)
		Combat.unregisterNPC(npcClone)
	end

	-- Primary: Humanoid.Died (model persists after death in this game)
	local humanoid = npcClone:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Died:Once(cleanup)
	end

	-- Fallback: model destroyed (admin removal, server shutdown, etc.)
	npcClone.Destroying:Connect(cleanup)

	-- Register with UnitManager only for player-owned NPCs
	if ownerPlayer then
		UnitManager.registerUnit(ownerPlayer, npcClone, npcType)
		UnitManager.updateUnitPosition(ownerPlayer, npcClone, spawnPos)
	end

	-- Register with combat system
	Combat.registerNPC(npcClone, ownerPlayer, role)

	return npcClone
end

return NPCSpawner
