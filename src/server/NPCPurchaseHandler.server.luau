-- NPCPurchaseHandler (MANPOWER VERSION)
-- NPCs now cost Manpower instead of Coins
-- Added rate limiting cooldown to prevent spam
-- Added CollectionService tagging for diagnostics tracking

local DEBUG = false

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BuyNPCEvent = ReplicatedStorage:WaitForChild("BuyNPCEvent", 10)
local DiplomacyReminderEvent = ReplicatedStorage:WaitForChild("DiplomacyReminderEvent", 10)

local TileManager = require(game.ServerScriptService:WaitForChild("TileManager", 10))
local ServerState = require(game.ServerScriptService:WaitForChild("ServerState", 10))
local NPCSpawner = require(game.ServerScriptService:WaitForChild("NPCSpawner", 10))

-- NPC costs in MANPOWER (not coins)
local NPC_COSTS = {
	AttackerNPC = 10000,
	DefenderNPC = 10000
}

-- Manpower income rate (mirrors CountryManager's flat 100-per-3s regen).
-- Used to estimate time-until-purchase for the InsufficientManpower reminder.
local MANPOWER_INTERVAL = 3
local BASE_MANPOWER_INCOME = 100

-- Rate limiting configuration
local PURCHASE_COOLDOWN = 0.5 -- Minimum seconds between purchases

local playerBuying = {}
local playerLastPurchase = {}

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
			if DiplomacyReminderEvent then
				-- Estimate seconds until the player has enough manpower.
				-- Only meaningful if they own a country (otherwise no income).
				local currentManpower = manpower and math.max(0, math.floor(manpower.Value)) or 0
				local secondsRemaining = -1
				if TileManager.getPlayerCountry(player) then
					local needed = cost - currentManpower
					if needed > 0 and BASE_MANPOWER_INCOME > 0 then
						secondsRemaining = math.ceil(needed * MANPOWER_INTERVAL / BASE_MANPOWER_INCOME)
					else
						secondsRemaining = 0
					end
				end
				DiplomacyReminderEvent:FireClient(player, nil, "InsufficientManpower", cost, secondsRemaining)
			end
			return
		end

		-- Tile reservation
		local spawnPos, tileKey = TileManager.getSpawnPosition(player)
		if not spawnPos or not tileKey then
			error("No valid tile found")
		end

		-- Transaction - deduct MANPOWER
		manpower.Value = math.floor(manpower.Value) - cost

		local countryName = TileManager.getPlayerCountry(player)
		if countryName then
			ServerState.addCountryManpower(countryName, -cost)  -- relative deduction, concurrent-safe
		end

		-- Spawn NPC via shared spawner (player-owned)
		local npcClone = NPCSpawner.spawnNPC(countryName, npcType, spawnPos, tileKey, player)
		if not npcClone then
			error("Failed to spawn NPC")
		end

		if DEBUG then print(player.Name .. " bought a " .. npcType .. " for " .. cost .. " manpower") end
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