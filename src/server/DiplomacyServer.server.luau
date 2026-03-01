-- DiplomacyServer - FIXED v3
-- FIX #1: Prevents duplicate war declarations
-- FIX #2: Better validation and error messages
-- FIX #3: Full conquest-chain resolution via ServerState.resolveTarget()

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

-- 1. REQUIREMENTS (Modules)
local DiplomacyManager = require(ServerScriptService:WaitForChild("DiplomacyManager", 10))
local ServerState = require(ServerScriptService:WaitForChild("ServerState", 10))
local TileOwnershipManager = require(ServerScriptService:WaitForChild("TileOwnershipManager", 10))

-- 2. REQUIREMENTS (Remotes)
local DeclareWarEvent = ReplicatedStorage:WaitForChild("DeclareWarEvent", 10)
local SendRequestEvent = ReplicatedStorage:WaitForChild("SendRequestEvent")
local BreakAllianceEvent = ReplicatedStorage:WaitForChild("BreakAllianceEvent", 10)
local GlobalNotificationEvent = ReplicatedStorage:WaitForChild("GlobalNotificationEvent", 10)
local DiplomacyResponse = ReplicatedStorage:WaitForChild("DiplomacyResponse", 10)
local DiplomacyRequest = ReplicatedStorage:WaitForChild("DiplomacyRequest", 10)

-- HELPER: Find which country a player currently owns
local function getPlayerCountry(player)
	local countryOwners = ServerState.getCountryOwners()
	for countryName, owner in pairs(countryOwners) do
		if owner == player then
			return countryName
		end
	end
	return nil
end

-- HELPER: Raw single-level lookup (used ONLY for pre-resolution early-exit checks,
-- e.g. "does this country exist?").
-- Do NOT use this to determine the controlling player — use ServerState.resolveTarget() instead.
local function getCountryOwner(countryName)
	local countryOwners = ServerState.getCountryOwners()
	return countryOwners[countryName]
end

---------------------------------------------------------
-- PART 1: WAR LOGIC (Instant Action) - FIXED
---------------------------------------------------------
DeclareWarEvent.OnServerEvent:Connect(function(player, targetCountryName)
	local playerCountry = getPlayerCountry(player)

	-- Validation Checks
	if not playerCountry then
		GlobalNotificationEvent:FireClient(player, "❌ You must own a country to declare war.", Color3.fromRGB(255, 100, 100))
		return
	end

	if playerCountry == targetCountryName then
		GlobalNotificationEvent:FireClient(player, "❌ You cannot declare war on yourself.", Color3.fromRGB(255, 100, 100))
		return
	end

	-- Raw pre-resolution checks (before chain-walking)
	local rawOwner = getCountryOwner(targetCountryName)

	-- Check if target country exists
	if rawOwner == nil then
		GlobalNotificationEvent:FireClient(player, "❌ That country doesn't exist.", Color3.fromRGB(255, 100, 100))
		return
	end

	-- Unowned countries (no player controlling them) are still valid war targets.
	-- NPCs may or may not be present — either way the country has territory on the map.
	-- (Conquered countries are handled below via the "Conquered_" chain resolution.)

	-- If target is conquered, resolve the full chain to the actual controlling country/player.
	-- ALL conquest-chain resolution goes through ServerState.resolveTarget() — no exceptions.
	if type(rawOwner) == "string" and rawOwner:find("Conquered_") then
		local canonicalName, controllingPlayer = ServerState.resolveTarget(targetCountryName)
		if not canonicalName then
			GlobalNotificationEvent:FireClient(player, "❌ That country's ruling power could not be determined.", Color3.fromRGB(255, 100, 100))
			return
		end

		-- Redirect war declaration to the canonical controlling country
		targetCountryName = canonicalName

		-- Re-validate after redirect
		local resolvedOwner = getCountryOwner(canonicalName)
		if not resolvedOwner then
			GlobalNotificationEvent:FireClient(player, "❌ The conquering country no longer exists.", Color3.fromRGB(255, 100, 100))
			return
		end
		-- Unowned conqueror is still a valid war target (country has territory)
		if targetCountryName == playerCountry then
			GlobalNotificationEvent:FireClient(player, "❌ You cannot declare war on yourself.", Color3.fromRGB(255, 100, 100))
			return
		end
	end

	-- Check if allied with target (must break alliance first)
	if DiplomacyManager.areCountriesAllied(playerCountry, targetCountryName) then
		GlobalNotificationEvent:FireClient(player, "You are allied with " .. targetCountryName .. "! Break the alliance first.", Color3.fromRGB(255, 200, 0))
		return
	end

	-- FIX #1: Use the return value from declareWar to check for duplicates
	local success, message = DiplomacyManager.declareWar(playerCountry, targetCountryName)

	if not success then
		if message == "Already at war" then
			GlobalNotificationEvent:FireClient(player, "⚠️ You are already at war with " .. targetCountryName .. "!", Color3.fromRGB(255, 200, 0))
		else
			GlobalNotificationEvent:FireClient(player, "❌ " .. (message or "Could not declare war."), Color3.fromRGB(255, 100, 100))
		end
		return
	end

	-- War declared successfully - notify everyone
	print("⚔️ WAR: " .. playerCountry .. " vs " .. targetCountryName)
	local msg = "⚠️ WAR: " .. playerCountry .. " has declared war on " .. targetCountryName .. "!"
	GlobalNotificationEvent:FireAllClients(msg, Color3.fromRGB(255, 80, 80))
end)

---------------------------------------------------------
-- PART 1.5: BREAK ALLIANCE LOGIC (Instant Action)
---------------------------------------------------------
BreakAllianceEvent.OnServerEvent:Connect(function(player, targetCountryName)
	local playerCountry = getPlayerCountry(player)

	-- Validation Checks
	if not playerCountry then
		GlobalNotificationEvent:FireClient(player, "❌ You must own a country to break an alliance.", Color3.fromRGB(255, 100, 100))
		return
	end

	if playerCountry == targetCountryName then
		GlobalNotificationEvent:FireClient(player, "❌ You cannot break an alliance with yourself.", Color3.fromRGB(255, 100, 100))
		return
	end

	local targetOwner = getCountryOwner(targetCountryName)

	-- Check if target country exists
	if targetOwner == nil then
		GlobalNotificationEvent:FireClient(player, "❌ That country doesn't exist.", Color3.fromRGB(255, 100, 100))
		return
	end

	-- Check if allied with target
	if not DiplomacyManager.areCountriesAllied(playerCountry, targetCountryName) then
		GlobalNotificationEvent:FireClient(player, "❌ You are not allied with " .. targetCountryName .. ".", Color3.fromRGB(255, 200, 0))
		return
	end

	-- Break the alliance
	DiplomacyManager.breakAlliance(playerCountry, targetCountryName)

	-- Notify everyone
	print("💔 ALLIANCE BROKEN: " .. playerCountry .. " broke alliance with " .. targetCountryName)
	local msg = "💔 " .. playerCountry .. " has broken their alliance with " .. targetCountryName .. "!"
	GlobalNotificationEvent:FireAllClients(msg, Color3.fromRGB(255, 100, 100))
end)

---------------------------------------------------------
-- PART 2: PEACE & ALLIANCE LOGIC (Request System)
---------------------------------------------------------
local function processRequest(senderPlayer, targetCountryName, requestType)
	local senderCountry = getPlayerCountry(senderPlayer)

	-- Resolve the full conquest chain to get canonical country name + controlling player.
	-- This is the single authoritative resolution path — no chain-walking anywhere else.
	local canonicalName, receiverPlayer = ServerState.resolveTarget(targetCountryName)
	if not canonicalName then
		GlobalNotificationEvent:FireClient(senderPlayer, "❌ That country's ruling power could not be determined.", Color3.fromRGB(255, 100, 100))
		return
	end
	targetCountryName = canonicalName

	-- Validation
	if not senderCountry then
		GlobalNotificationEvent:FireClient(senderPlayer, "❌ You must own a country first.", Color3.fromRGB(255, 100, 100))
		return
	end

	if not receiverPlayer then
		GlobalNotificationEvent:FireClient(senderPlayer, "❌ That country has no owner.", Color3.fromRGB(255, 100, 100))
		return
	end

	if senderPlayer == receiverPlayer then
		GlobalNotificationEvent:FireClient(senderPlayer, "❌ You cannot send requests to yourself.", Color3.fromRGB(255, 100, 100))
		return
	end

	-- receiverPlayer is guaranteed to be a Player instance by resolveTarget(),
	-- but keep the safety check so any unexpected value surfaces clearly.
	if typeof(receiverPlayer) ~= "Instance" or not receiverPlayer:IsA("Player") then
		GlobalNotificationEvent:FireClient(senderPlayer, "❌ Cannot send requests to AI/unowned countries.", Color3.fromRGB(255, 200, 0))
		return
	end

	-- Check if player is still in game
	if not receiverPlayer.Parent then
		GlobalNotificationEvent:FireClient(senderPlayer, "❌ That player has left the game.", Color3.fromRGB(255, 100, 100))
		return
	end

	-- Additional validation for peace requests
	if requestType == "Peace" then
		if not DiplomacyManager.areCountriesAtWar(senderCountry, targetCountryName) then
			GlobalNotificationEvent:FireClient(senderPlayer, "⚠️ You are not at war with " .. targetCountryName .. ".", Color3.fromRGB(255, 200, 0))
			return
		end
	end

	-- Additional validation for alliance requests
	if requestType == "Alliance" then
		if DiplomacyManager.areCountriesAtWar(senderCountry, targetCountryName) then
			GlobalNotificationEvent:FireClient(senderPlayer, "You are at war with " .. targetCountryName .. "! Sign peace first.", Color3.fromRGB(255, 200, 0))
			return
		end
	end

	print("📨 Sending " .. requestType .. " request from " .. senderCountry .. " to " .. targetCountryName)

	-- FIX: Use fire-and-response pattern instead of InvokeClient
	-- Store the pending request to handle the response
	local requestId = tostring(tick())
	ServerState.setPendingDiplomacyRequest(requestId, {
		senderPlayer = senderPlayer,
		receiverPlayer = receiverPlayer,
		senderCountry = senderCountry,
		targetCountryName = targetCountryName,
		requestType = requestType
	})

	-- Fire to client to show the popup
	DiplomacyRequest:FireClient(receiverPlayer, senderCountry, requestType, requestId)

	-- The response will be handled by DiplomacyResponse.OnServerEvent below
end

-- Connect the UI buttons to this logic
SendRequestEvent.OnServerEvent:Connect(function(player, targetCountryName, requestType)
	task.spawn(function()
		processRequest(player, targetCountryName, requestType)
	end)
end)

---------------------------------------------------------
-- PART 3: DIPLOMACY RESPONSE HANDLER (FIX)
---------------------------------------------------------

-- Handle responses from clients using the new RemoteEvent
DiplomacyResponse.OnServerEvent:Connect(function(player, requestId, accepted)
	local requestData = ServerState.getPendingDiplomacyRequest(requestId)
	if not requestData then
		warn("[DiplomacyServer] Received response for unknown request: " .. requestId)
		return
	end

	-- Verify this is the correct player responding
	if player ~= requestData.receiverPlayer then
		warn("[DiplomacyServer] Player " .. player.Name .. " attempted to respond to a request not for them.")
		return
	end

	-- Clean up the pending request
	ServerState.clearPendingDiplomacyRequest(requestId)

	local senderPlayer = requestData.senderPlayer
	local senderCountry = requestData.senderCountry
	local targetCountryName = requestData.targetCountryName
	local requestType = requestData.requestType

	-- Check if sender is still in game
	if not senderPlayer.Parent then
		print("[DiplomacyServer] Sender " .. senderPlayer.Name .. " left the game before response was received.")
		return
	end

	if accepted then
		if requestType == "Alliance" then
			DiplomacyManager.formAlliance(senderCountry, targetCountryName)
			GlobalNotificationEvent:FireAllClients("🤝 ALLIANCE: " .. senderCountry .. " and " .. targetCountryName .. " are now allies!", Color3.fromRGB(100, 255, 100))
		elseif requestType == "Peace" then
			DiplomacyManager.makePeace(senderCountry, targetCountryName)
			-- FIX: Annex occupied tiles instead of releasing them
			-- Each country keeps whatever territory they occupied during the war
			local senderAnnexed = TileOwnershipManager.annexOccupiedTiles(senderCountry)
			local targetAnnexed = TileOwnershipManager.annexOccupiedTiles(targetCountryName)

			local annexMsg = ""
			if senderAnnexed > 0 then
				annexMsg = annexMsg .. senderCountry .. " annexed " .. senderAnnexed .. " tiles. "
			end
			if targetAnnexed > 0 then
				annexMsg = annexMsg .. targetCountryName .. " annexed " .. targetAnnexed .. " tiles. "
			end

			GlobalNotificationEvent:FireAllClients("🕊️ PEACE: " .. senderCountry .. " and " .. targetCountryName .. " have signed a treaty. " .. annexMsg, Color3.fromRGB(100, 200, 255))
		end
	else
		GlobalNotificationEvent:FireClient(senderPlayer, "❌ " .. targetCountryName .. " rejected your " .. requestType .. " request.", Color3.fromRGB(255, 200, 0))
	end
end)
