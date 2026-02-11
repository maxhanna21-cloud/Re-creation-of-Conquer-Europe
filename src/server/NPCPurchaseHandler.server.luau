-- NPCPurchaseHandler (MANPOWER VERSION) - FIXED v3
-- NPCs now cost Manpower instead of Coins
-- FIX v2: Added rate limiting cooldown to prevent spam
-- FIX v3: Added CollectionService tagging for diagnostics tracking

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")
local CollectionService = game:GetService("CollectionService")
local BuyNPCEvent = ReplicatedStorage:WaitForChild("BuyNPCEvent", 10)

local Combat = require(game.ServerScriptService:WaitForChild("NPCCombatSystem", 10))
local TileManager = require(game.ServerScriptService:WaitForChild("TileManager", 10))
local UnitManager = require(game.ServerScriptService:WaitForChild("UnitManager", 10))
local ServerState = require(game.ServerScriptService:WaitForChild("ServerState", 10))
local TileOwnershipManager = require(game.ServerScriptService:WaitForChild("TileOwnershipManager", 10))

-- NPC Tag for diagnostics
local NPC_TAG = "RegisteredNPC"

-- NPC costs in MANPOWER (not coins)
local NPC_COSTS = {
	AttackerNPC = 10000,
	DefenderNPC = 10000
}

-- Rate limiting configuration
local PURCHASE_COOLDOWN = 0.5 -- Minimum seconds between purchases

local playerBuying = {}
local playerLastPurchase = {}

local function setNPCCollisionGroup(npcModel)
	for _, part in ipairs(npcModel:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CollisionGroup = "NPCs"
		end
	end
end

-- FIX v3: Tag NPC for diagnostics tracking
local function tagNPCForDiagnostics(npcModel)
	if npcModel and npcModel:IsA("Model") then
		CollectionService:AddTag(npcModel, NPC_TAG)
	end
end

-- Set NPC body color to match country color
local function setNPCBodyColor(npcModel, countryName)
	local countryColor = TileOwnershipManager.getCountryColor(countryName)
	if not countryColor then return end

	for _, part in ipairs(npcModel:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Color = countryColor
		end
	end
end

BuyNPCEvent.OnServerEvent:Connect(function(player, npcType)
	-- Per-player lock
	if playerBuying[player] then
		warn("Purchase skipped: Still processing for " .. player.Name)
		return
	end

	-- Rate limiting check
	local now = os.clock()
	local lastPurchase = playerLastPurchase[player] or 0
	if (now - lastPurchase) < PURCHASE_COOLDOWN then
		warn("Purchase skipped: Rate limited for " .. player.Name .. " (too fast)")
		return
	end

	playerBuying[player] = true
	playerLastPurchase[player] = now

	-- Wrap everything in pcall to GUARANTEE lock release
	local success, errorMsg = pcall(function()
		-- Validation
		local cost = NPC_COSTS[npcType]
		if not cost then
			error("Invalid NPC type: " .. tostring(npcType))
		end

		local stats = player:FindFirstChild("leaderstats")
		local manpower = stats and stats:FindFirstChild("Manpower")

		if not manpower or math.floor(manpower.Value) < cost then
			error("Insufficient manpower (need " .. cost .. ")")
		end

		-- Tile reservation
		local spawnPos, tileKey = TileManager.getSpawnPosition(player)
		if not spawnPos or not tileKey then
			error("No valid tile found")
		end

		-- Transaction - deduct MANPOWER
		manpower.Value = math.floor(manpower.Value) - cost

		-- Also sync to country storage
		local countryName = TileManager.getPlayerCountry(player)
		if countryName then
			ServerState.setCountryManpower(countryName, manpower.Value)
		end

		-- Spawn NPC
		local npcTemplate = ReplicatedStorage:FindFirstChild(npcType)
		if not npcTemplate then
			error("Template not found: " .. npcType)
		end

		local npcClone = npcTemplate:Clone()
		setNPCCollisionGroup(npcClone)
		setNPCBodyColor(npcClone, countryName)
		local role = (npcType == "DefenderNPC") and "Defender" or "Attacker"

		-- Setup ownership
		local ownerVal = Instance.new("ObjectValue")
		ownerVal.Name = "NPCOwner"
		ownerVal.Value = player
		ownerVal.Parent = npcClone

		npcClone.Name = npcType
		npcClone:PivotTo(CFrame.new(spawnPos))
		npcClone.Parent = workspace

		-- Mark tile as occupied
		TileManager.occupyTile(countryName, tileKey, npcClone)

		-- Store tile info for cleanup
		npcClone:SetAttribute("TileKey", tileKey)
		npcClone:SetAttribute("Country", countryName)

		-- FIX v3: Tag NPC for diagnostics
		tagNPCForDiagnostics(npcClone)

		-- Release tile when NPC dies/destroyed
		npcClone.Destroying:Connect(function()
			local key = npcClone:GetAttribute("TileKey")
			local country = npcClone:GetAttribute("Country")
			if key and country then
				TileManager.releaseTile(country, key)
			end
			-- Remove tag on destroy
			CollectionService:RemoveTag(npcClone, NPC_TAG)
		end)

		-- Register with systems
		UnitManager.registerUnit(player, npcClone, npcType)
		UnitManager.updateUnitPosition(player, npcClone, spawnPos)
		Combat.registerNPC(npcClone, player, role)

		print(player.Name .. " bought a " .. npcType .. " for " .. cost .. " manpower")
	end)

	-- ALWAYS release lock
	playerBuying[player] = nil

	if not success then
		warn("NPC Purchase failed: " .. tostring(errorMsg))
	end
end)

-- Cleanup when player leaves
game.Players.PlayerRemoving:Connect(function(player)
	playerBuying[player] = nil
	playerLastPurchase[player] = nil
end)