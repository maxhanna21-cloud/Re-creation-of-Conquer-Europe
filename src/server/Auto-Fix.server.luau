-- Auto-Fix NPCs Script (COUNTRY PERSISTENCE VERSION) - FIXED
-- Handles country-owned NPCs that are waiting for a player to claim the country
-- FIX #2: Race condition fix - use transferOwnership instead of registerNPC when loop already running
local Combat = require(game.ServerScriptService:WaitForChild("NPCCombatSystem", 10))
local ServerState = require(game.ServerScriptService:WaitForChild("ServerState", 10))
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")


local CHECK_INTERVAL = 3 -- Check every 3 seconds
local lastCheck = 0


local function fixNPC(npc)
	if not npc or not npc.Parent then return end


	-- If already properly registered and running, skip
	if Combat.getOwner(npc) and Combat.isLoopRunning(npc) then
		return
	end


	local owner = Combat.getOwner(npc)
	local role = Combat.getRole(npc)
	local npcCountry = npc:GetAttribute("Country")


	-- 1. CHECK IF THIS IS A COUNTRY-OWNED NPC (waiting for player)
	if npcCountry then
		local CountryOwners = ServerState.getCountryOwners()
		local countryOwner = CountryOwners[npcCountry]


		-- If the country has a player owner, this NPC should belong to them
		if typeof(countryOwner) == "Instance" and countryOwner:IsA("Player") and countryOwner.Parent then
			-- Country has an active player - make sure NPC is assigned to them
			if owner ~= countryOwner then
				print("[AUTO-FIX] Assigning " .. npc.Name .. " to country owner " .. countryOwner.Name)


				-- Update the ObjectValue
				local ownerVal = npc:FindFirstChild("NPCOwner")
				if ownerVal then
					ownerVal.Value = countryOwner
				end


				-- Determine role if not set
				if not role then
					role = (npc.Name:find("Defender")) and "Defender" or "Attacker"
				end


				-- FIX #2: Check loop status ONCE and act accordingly
				-- Use transferOwnership if loop is running, registerNPC if not
				if Combat.isLoopRunning(npc) then
					Combat.transferOwnership(npc, countryOwner)
				else
					Combat.registerNPC(npc, countryOwner, role)
				end
			end
			return
		else
			-- Country is unowned - NPC should be idle (country-owned)
			-- This is VALID state, don't destroy or modify
			if Combat.getOwner(npc) ~= nil then
				-- Clear the owner so NPC goes idle
				Combat.transferOwnership(npc, nil)
				local ownerVal = npc:FindFirstChild("NPCOwner")
				if ownerVal then
					ownerVal.Value = nil
				end
				print("[AUTO-FIX] " .. npc.Name .. " set to country-owned (idle) for " .. npcCountry)
			end
			return
		end
	end


	-- 2. ORPHAN CHECK: NPC has no country - check if owner left
	if owner and typeof(owner) == "Instance" and owner:IsA("Player") then
		if not owner.Parent then
			-- Owner left game and NPC has no country - this shouldn't happen normally
			-- but clean it up just in case
			print("[AUTO-FIX] Player owner left and NPC has no country. Cleaning up: " .. npc.Name)
			Combat.unregisterNPC(npc)
			npc:Destroy()
			return
		end
	end


	-- 3. SAFETY: If no owner in table, try to restore from ObjectValue
	local ownerToRegister = owner
	if not ownerToRegister then
		local ownerVal = npc:FindFirstChild("NPCOwner")
		if ownerVal and ownerVal.Value then
			if ownerVal.Value:IsA("Player") and ownerVal.Value.Parent then
				ownerToRegister = ownerVal.Value
				print("[AUTO-FIX] Restored owner from ObjectValue:", ownerToRegister.Name)
			elseif ownerVal.Value == Combat.getServerOwner() then
				ownerToRegister = ownerVal.Value
				print("[AUTO-FIX] Restored ServerOwner from ObjectValue")
			end
		end
	end


	-- If still no owner and no country, this NPC is orphaned
	if not ownerToRegister and not npcCountry then
		print("[AUTO-FIX] Orphaned NPC with no owner or country: " .. npc.Name)
		-- Don't destroy - might be a bug. Just log it.
		return
	end


	-- 4. ROLE CHECK (If role was not found, assign it based on name)
	if not role then
		role = (npc.Name:find("Defender")) and "Defender" or "Attacker"
		print("[AUTO-FIX] Restored role based on name:", role)
	end


	-- 5. LOOP CHECK: If logic stopped and we have a valid owner, restart it
	-- FIX #2: Only register if we have an owner AND loop is NOT running AND not already tracked
	if ownerToRegister and not Combat.isLoopRunning(npc) and not Combat.getOwner(npc) then
		Combat.registerNPC(npc, ownerToRegister, role)
		print("[AUTO-FIX] Restarted combat loop for " .. npc.Name)
	end
end


-- Heartbeat: check all NPCs every CHECK_INTERVAL seconds
RunService.Heartbeat:Connect(function(deltaTime)
	lastCheck = lastCheck + deltaTime
	if lastCheck >= CHECK_INTERVAL then
		lastCheck = 0

		-- FIX: Use CollectionService for efficient NPC tracking instead of iterating workspace
		local npcs = CollectionService:GetTagged("RegisteredNPC")
		for _, npc in ipairs(npcs) do
			if npc and npc.Parent then
				fixNPC(npc)
			end
		end
	end
end)