-- Clean NPC Diagnostics (COUNTRY PERSISTENCE VERSION) - FIXED v2
-- FIX: Uses CollectionService tags instead of iterating all workspace children
-- Now understands country-owned NPCs as a valid state

local Combat = require(game.ServerScriptService:WaitForChild("NPCCombatSystem", 10))
local ServerState = require(game.ServerScriptService:WaitForChild("ServerState", 10))
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local NPC_TAG = "RegisteredNPC" -- Tag applied to all NPCs

local CHECK_INTERVAL = 10
local lastCheck = 0

-- Helper function to tag NPCs when registered
-- Call this from NPCPurchaseHandler after spawning an NPC
function _G.TagNPCForDiagnostics(npcModel)
	if npcModel and npcModel:IsA("Model") then
		CollectionService:AddTag(npcModel, NPC_TAG)
	end
end

-- Helper function to untag NPCs when destroyed
function _G.UntagNPCForDiagnostics(npcModel)
	if npcModel and npcModel:IsA("Model") then
		CollectionService:RemoveTag(npcModel, NPC_TAG)
	end
end

RunService.Heartbeat:Connect(function(deltaTime)
	lastCheck = lastCheck + deltaTime
	if lastCheck >= CHECK_INTERVAL then
		lastCheck = 0

		local totalCount = 0
		local activeCount = 0
		local idleCount = 0
		local issues = 0

		-- FIX: Use CollectionService to get only tagged NPCs
		local taggedNPCs = CollectionService:GetTagged(NPC_TAG)

		-- If no tagged NPCs, fall back to scanning workspace (backwards compatibility)
		local npcsToCheck = taggedNPCs
		if #npcsToCheck == 0 then
			npcsToCheck = {}
			for _, model in ipairs(workspace:GetChildren()) do
				if model:IsA("Model") and model:FindFirstChild("Humanoid") and model:FindFirstChild("NPCOwner") then
					table.insert(npcsToCheck, model)
				end
			end
		end

		for _, model in ipairs(npcsToCheck) do
			-- Validate model still exists and is an NPC
			if not model or not model.Parent then continue end
			if not model:FindFirstChild("Humanoid") then continue end
			if not model:FindFirstChild("NPCOwner") then continue end

			totalCount = totalCount + 1

			local owner = Combat.getOwner(model)
			local isRunning = Combat.isLoopRunning(model)
			local npcCountry = model:GetAttribute("Country")

			-- Check if owner is valid (Player OR ServerOwner OR nil for country-owned)
			local isValidOwner = false
			local isCountryOwned = false
			local issueAlreadyLogged = false

			if owner then
				isValidOwner = owner:IsA("Player") or owner == Combat.getServerOwner()
			elseif npcCountry then
				-- No owner but has country = country-owned (valid idle state)
				local CountryOwners = ServerState.getCountryOwners()
				local countryOwner = CountryOwners[npcCountry]

				if countryOwner == "Unowned" then
					isCountryOwned = true
					isValidOwner = true -- Country-owned is valid
					idleCount = idleCount + 1
				elseif typeof(countryOwner) == "Instance" and countryOwner:IsA("Player") then
					-- Country has owner but NPC doesn't - this is an issue
					isValidOwner = false
					warn("Diagnostic: " .. model.Name .. " should belong to " .. countryOwner.Name .. " but has no owner")
					issues = issues + 1
					issueAlreadyLogged = true
				end
			end

			if isValidOwner and not isCountryOwned then
				activeCount = activeCount + 1
			end

			-- Only log missing owner issue if we haven't already logged a specific issue
			if not isValidOwner and not isCountryOwned and not issueAlreadyLogged then
				issues = issues + 1
				warn("Diagnostic: " .. model.Name .. " missing valid owner or owner data is corrupted.")
			end

			-- Check for loop issues (only for player-owned NPCs)
			if not isRunning and not isCountryOwned then
				-- Loop should be running for player-owned NPCs
				if isValidOwner then
					issues = issues + 1
					warn("Diagnostic: " .. model.Name .. " loop inactive but has valid owner.")
				end
			end
		end

		if totalCount > 0 then
			print(string.format("--- DIAGNOSTICS: %d Total NPCs | %d Active | %d Country-Owned (Idle) | %d Issues ---", 
				totalCount, activeCount, idleCount, issues))
		end
	end
end)

print("[NPCDiagnostics] Initialized - Use _G.TagNPCForDiagnostics(npc) to register NPCs for tracking")