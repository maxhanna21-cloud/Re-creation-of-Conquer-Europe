-- DiplomacyManager
-- Added duplicate war declaration prevention
-- Wars persist when players leave - new player inherits wars
-- Added country-level war checks for NPC combat
-- NAPs are now timed truces: stored as os.clock() expiration timestamps

local DiplomacyManager = {}
local DEBUG = false
local ServerState = require(game:GetService("ServerScriptService"):WaitForChild("ServerState", 10))
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Default NAP duration in seconds (5 minutes)
local DEFAULT_NAP_DURATION = 300

-- Lazy load to avoid circular dependency
local TileManager = nil
local function getTileManager()
	if not TileManager then
		TileManager = require(game:GetService("ServerScriptService"):WaitForChild("TileManager", 10))
	end
	return TileManager
end

-- Data Structure:
-- Wars["France"] = { ["Germany"] = true }
-- Alliances["France"] = { ["Germany"] = true }
-- NonAggressionPacts["France"] = { ["Germany"] = <os.clock() expiration timestamp> }
local Wars = {}
local Alliances = {}
local NonAggressionPacts = {}

function DiplomacyManager.initCountry(countryName)
	if not Wars[countryName] then
		Wars[countryName] = {}
	end
	if not Alliances[countryName] then
		Alliances[countryName] = {}
	end
	if not NonAggressionPacts[countryName] then
		NonAggressionPacts[countryName] = {}
	end
end

-- Check if two COUNTRIES are at war (not players)
function DiplomacyManager.areCountriesAtWar(countryA, countryB)
	if not countryA or not countryB then return false end
	if countryA == countryB then return false end

	return (Wars[countryA] and Wars[countryA][countryB] == true) or false
end

-- Check if two COUNTRIES are allied
function DiplomacyManager.areCountriesAllied(countryA, countryB)
	if not countryA or not countryB then return false end
	if countryA == countryB then return true end

	return (Alliances[countryA] and Alliances[countryA][countryB] == true) or false
end

-- Check if two COUNTRIES have a Non-Aggression Pact (timed truce)
-- Returns true only if a pact exists AND has not yet expired
function DiplomacyManager.hasNonAggressionPact(countryA, countryB)
	if not countryA or not countryB then return false end
	if countryA == countryB then return true end

	local expiresAt = NonAggressionPacts[countryA] and NonAggressionPacts[countryA][countryB]
	if type(expiresAt) == "number" and expiresAt > os.clock() then
		return true
	end

	return false
end

-- Get the remaining time (in seconds) on a NAP between two countries
-- Returns 0 if no active pact exists
function DiplomacyManager.getNAPTimeRemaining(countryA, countryB)
	if not countryA or not countryB then return 0 end
	if countryA == countryB then return 0 end

	local expiresAt = NonAggressionPacts[countryA] and NonAggressionPacts[countryA][countryB]
	if type(expiresAt) == "number" then
		local remaining = expiresAt - os.clock()
		if remaining > 0 then
			return remaining
		end
	end

	return 0
end

-- Get the absolute expiration timestamp for a NAP (for sending to clients)
-- Returns nil if no active pact exists
function DiplomacyManager.getNAPExpiresAt(countryA, countryB)
	if not countryA or not countryB then return nil end
	if countryA == countryB then return nil end

	local expiresAt = NonAggressionPacts[countryA] and NonAggressionPacts[countryA][countryB]
	if type(expiresAt) == "number" and expiresAt > os.clock() then
		return expiresAt
	end

	return nil
end

-- Declare War - Returns false if already at war
function DiplomacyManager.declareWar(attackerCountry, defenderCountry)
	if not attackerCountry or not defenderCountry then
		return false, "Invalid countries"
	end

	if attackerCountry == defenderCountry then
		return false, "Cannot declare war on yourself"
	end

	if DiplomacyManager.areCountriesAtWar(attackerCountry, defenderCountry) then
		return false, "Already at war"
	end

	if DiplomacyManager.areCountriesAllied(attackerCountry, defenderCountry) then
		return false, "You are allied. Break the alliance first."
	end

	if DiplomacyManager.hasNonAggressionPact(attackerCountry, defenderCountry) then
		return false, "A Non-Aggression Pact is active. Break it first."
	end

	if not Wars[attackerCountry] then DiplomacyManager.initCountry(attackerCountry) end
	if not Wars[defenderCountry] then DiplomacyManager.initCountry(defenderCountry) end

	-- Break any existing alliance or NAP first (safeguard)
	if Alliances[attackerCountry] then Alliances[attackerCountry][defenderCountry] = nil end
	if Alliances[defenderCountry] then Alliances[defenderCountry][attackerCountry] = nil end
	if NonAggressionPacts[attackerCountry] then NonAggressionPacts[attackerCountry][defenderCountry] = nil end
	if NonAggressionPacts[defenderCountry] then NonAggressionPacts[defenderCountry][attackerCountry] = nil end

	-- War is mutual
	Wars[attackerCountry][defenderCountry] = true
	Wars[defenderCountry][attackerCountry] = true

	if DEBUG then print("WAR DECLARED: " .. attackerCountry .. " vs " .. defenderCountry) end
	return true, "War declared"
end

-- Make Peace
function DiplomacyManager.makePeace(countryA, countryB)
	if not countryA or not countryB then return false end

	if Wars[countryA] then Wars[countryA][countryB] = nil end
	if Wars[countryB] then Wars[countryB][countryA] = nil end
	if DEBUG then print("PEACE SIGNED: " .. countryA .. " and " .. countryB) end
	return true
end

-- Clear all wars for a country (called when country is conquered)
function DiplomacyManager.clearAllWarsForCountry(countryName)
	if not countryName then return end

	local enemies = {}
	if Wars[countryName] then
		for enemy, atWar in pairs(Wars[countryName]) do
			if atWar then
				table.insert(enemies, enemy)
			end
		end
	end

	-- Remove bilateral war entries
	for _, enemy in ipairs(enemies) do
		if Wars[enemy] then
			Wars[enemy][countryName] = nil
		end
	end

	-- Clear the conquered country's wars table
	Wars[countryName] = {}

	if DEBUG then print("WARS CLEARED: " .. countryName .. " (was at war with " .. #enemies .. " countries)") end
end

-- Clear all alliances for a country (called when country is conquered)
function DiplomacyManager.clearAllAlliancesForCountry(countryName)
	if not countryName then return end

	local allies = {}
	if Alliances[countryName] then
		for ally, isAllied in pairs(Alliances[countryName]) do
			if isAllied then
				table.insert(allies, ally)
			end
		end
	end

	-- Remove bilateral alliance entries
	for _, ally in ipairs(allies) do
		if Alliances[ally] then
			Alliances[ally][countryName] = nil
		end
	end

	-- Clear the conquered country's alliances table
	Alliances[countryName] = {}

	if DEBUG then print("ALLIANCES CLEARED: " .. countryName .. " (was allied with " .. #allies .. " countries)") end
end

-- Clear all NAPs for a country (called when country is conquered)
function DiplomacyManager.clearAllNAPsForCountry(countryName)
	if not countryName then return end

	local partners = {}
	if NonAggressionPacts[countryName] then
		for partner, expiresAt in pairs(NonAggressionPacts[countryName]) do
			if type(expiresAt) == "number" then
				table.insert(partners, partner)
			end
		end
	end

	-- Remove bilateral NAP entries
	for _, partner in ipairs(partners) do
		if NonAggressionPacts[partner] then
			NonAggressionPacts[partner][countryName] = nil
		end
	end

	-- Clear the conquered country's NAPs table
	NonAggressionPacts[countryName] = {}

	if DEBUG then print("NAPS CLEARED: " .. countryName .. " (had NAPs with " .. #partners .. " countries)") end
end

-- Clear ALL diplomacy for a country (wars, alliances, NAPs) — single call for conquest cleanup
function DiplomacyManager.clearAllDiplomacyForCountry(countryName)
	if not countryName then return end

	DiplomacyManager.clearAllWarsForCountry(countryName)
	DiplomacyManager.clearAllAlliancesForCountry(countryName)
	DiplomacyManager.clearAllNAPsForCountry(countryName)

	if DEBUG then print("ALL DIPLOMACY CLEARED: " .. countryName) end
end

-- Get country from player OR from NPC's country attribute
local function getEntityCountry(entity)
	if not entity then return nil end

	if typeof(entity) == "Instance" and entity:IsA("Player") then
		return getTileManager().getPlayerCountry(entity)
	end

	if type(entity) == "string" then
		return entity
	end

	return nil
end

-- CHECK: Are these two players at war? (checks their countries)
function DiplomacyManager.areAtWar(playerA, playerB)
	if not playerA or not playerB then
		return false
	end

	if playerA == playerB then
		return false
	end

	local countryA = getEntityCountry(playerA)
	local countryB = getEntityCountry(playerB)

	if not countryA or not countryB then
		return false
	end

	return DiplomacyManager.areCountriesAtWar(countryA, countryB)
end

-- Check if an NPC's country is at war with another NPC's country
-- This works even when countries are unowned
function DiplomacyManager.areNPCsAtWar(npcA, npcB)
	if not npcA or not npcB then return false end

	local countryA = npcA:GetAttribute("Country")
	local countryB = npcB:GetAttribute("Country")

	if not countryA or not countryB then return false end

	return DiplomacyManager.areCountriesAtWar(countryA, countryB)
end

-- Check if NPC can attack based on country-level diplomacy
function DiplomacyManager.canNPCAttack(attackerNPC, targetNPC)
	if not attackerNPC or not targetNPC then return false end

	local attackerCountry = attackerNPC:GetAttribute("Country")
	local targetCountry = targetNPC:GetAttribute("Country")

	if not attackerCountry or not targetCountry then return false end

	-- Same country = no friendly fire
	if attackerCountry == targetCountry then
		return false
	end

	-- Check if allied
	if DiplomacyManager.areCountriesAllied(attackerCountry, targetCountry) then
		return false
	end

	-- Must be at war
	return DiplomacyManager.areCountriesAtWar(attackerCountry, targetCountry)
end

-- FORM ALLIANCE
function DiplomacyManager.formAlliance(countryA, countryB)
	if not countryA or not countryB then return false end
	if countryA == countryB then return false end

	if not Alliances[countryA] then Alliances[countryA] = {} end
	if not Alliances[countryB] then Alliances[countryB] = {} end

	Alliances[countryA][countryB] = true
	Alliances[countryB][countryA] = true

	DiplomacyManager.makePeace(countryA, countryB)

	if DEBUG then print("ALLIANCE FORMED: " .. countryA .. " and " .. countryB) end
	return true
end

-- Break Alliance
function DiplomacyManager.breakAlliance(countryA, countryB)
	if Alliances[countryA] then Alliances[countryA][countryB] = nil end
	if Alliances[countryB] then Alliances[countryB][countryA] = nil end
	if DEBUG then print("ALLIANCE BROKEN: " .. countryA .. " and " .. countryB) end
end

-- FORM NON-AGGRESSION PACT (timed truce)
-- duration: seconds until the pact expires (defaults to DEFAULT_NAP_DURATION)
function DiplomacyManager.formNonAggressionPact(countryA, countryB, duration)
	if not countryA or not countryB then return false end
	if countryA == countryB then return false end

	duration = duration or DEFAULT_NAP_DURATION
	local expiresAt = os.clock() + duration

	if not NonAggressionPacts[countryA] then NonAggressionPacts[countryA] = {} end
	if not NonAggressionPacts[countryB] then NonAggressionPacts[countryB] = {} end

	NonAggressionPacts[countryA][countryB] = expiresAt
	NonAggressionPacts[countryB][countryA] = expiresAt

	DiplomacyManager.makePeace(countryA, countryB)

	if DEBUG then print("NAP FORMED: " .. countryA .. " and " .. countryB .. " (expires in " .. duration .. "s)") end
	return true
end

-- BREAK NON-AGGRESSION PACT (manual break by a player)
function DiplomacyManager.breakNonAggressionPact(countryA, countryB)
	if NonAggressionPacts[countryA] then NonAggressionPacts[countryA][countryB] = nil end
	if NonAggressionPacts[countryB] then NonAggressionPacts[countryB][countryA] = nil end
	if DEBUG then print("NAP BROKEN: " .. countryA .. " and " .. countryB) end
end

-- CHECK ALLIANCE
function DiplomacyManager.areAllied(playerA, playerB)
	if not playerA or not playerB then
		return false
	end

	if playerA == playerB then
		return true
	end

	local countryA = getEntityCountry(playerA)
	local countryB = getEntityCountry(playerB)

	if not countryA or not countryB then
		return false
	end

	return DiplomacyManager.areCountriesAllied(countryA, countryB)
end

-- Legacy canAttack for player-based checks
function DiplomacyManager.canAttack(attackerOwner, targetOwner)
	if attackerOwner and targetOwner and attackerOwner == targetOwner then
		return false
	end

	if not attackerOwner or not targetOwner then
		return false
	end

	if DiplomacyManager.areAllied(attackerOwner, targetOwner) then
		return false
	end

	return DiplomacyManager.areAtWar(attackerOwner, targetOwner)
end

-- Get all countries at war with a given country
-- Filter out conquered countries from the enemy list
function DiplomacyManager.getEnemies(countryName)
	local enemies = {}
	local CountryOwners = ServerState.getCountryOwners()

	if Wars[countryName] then
		for enemy, atWar in pairs(Wars[countryName]) do
			if atWar then
				-- Filter out conquered countries
				local enemyOwner = CountryOwners[enemy]
				local isConquered = type(enemyOwner) == "string" and enemyOwner:find("Conquered_")
				if not isConquered then
					table.insert(enemies, enemy)
				end
			end
		end
	end
	return enemies
end

-- Get all allied countries
function DiplomacyManager.getAllies(countryName)
	local allies = {}
	if Alliances[countryName] then
		for ally, isAllied in pairs(Alliances[countryName]) do
			if isAllied then
				table.insert(allies, ally)
			end
		end
	end
	return allies
end

-- Get all countries with an active NAP with the given country
function DiplomacyManager.getNAPPartners(countryName)
	local partners = {}
	local now = os.clock()
	if NonAggressionPacts[countryName] then
		for partner, expiresAt in pairs(NonAggressionPacts[countryName]) do
			if type(expiresAt) == "number" and expiresAt > now then
				table.insert(partners, partner)
			end
		end
	end
	return partners
end

-- Check if a country is at war with anyone
function DiplomacyManager.isAtWarWithAnyone(countryName)
	if Wars[countryName] then
		for _, atWar in pairs(Wars[countryName]) do
			if atWar then
				return true
			end
		end
	end
	return false
end

-- Debug
function DiplomacyManager.debugPrintWars()
	if not DEBUG then return end
	print("=== ACTIVE WARS ===")
	local printed = {}
	for countryA, enemies in pairs(Wars) do
		for countryB, atWar in pairs(enemies) do
			if atWar then
				local key = countryA < countryB and (countryA.."-"..countryB) or (countryB.."-"..countryA)
				if not printed[key] then
					print("  " .. countryA .. " vs " .. countryB)
					printed[key] = true
				end
			end
		end
	end
	print("===================")
end

---------------------------------------------------------
-- NAP EXPIRATION SWEEP (Server-side only)
---------------------------------------------------------
-- Runs every 5 seconds, checks all NAPs for expiration.
-- Expired pacts are removed bilaterally and a global notification is fired.
-- This only runs on the server (RunService:IsServer()).

if RunService:IsServer() then
	local NAP_SWEEP_INTERVAL = 5
	local lastSweep = os.clock()

	-- Callback for on-expiry notification (set by DiplomacyServer via setNAPExpiredCallback)
	local napExpiredCallback = nil

	function DiplomacyManager.setNAPExpiredCallback(callback)
		napExpiredCallback = callback
	end

	local sweepConnection = RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - lastSweep < NAP_SWEEP_INTERVAL then
			return
		end
		lastSweep = now

		-- Collect expired pacts first, then remove (avoid mutating during iteration)
		local expired = {}
		local seen = {}

		for countryA, pacts in pairs(NonAggressionPacts) do
			for countryB, expiresAt in pairs(pacts) do
				if type(expiresAt) == "number" and expiresAt <= now then
					-- Deduplicate: only process each pair once
					local key = countryA < countryB and (countryA .. "|" .. countryB) or (countryB .. "|" .. countryA)
					if not seen[key] then
						seen[key] = true
						table.insert(expired, { countryA, countryB })
					end
				end
			end
		end

		-- Remove expired pacts and notify
		for _, pair in ipairs(expired) do
			local a, b = pair[1], pair[2]
			if NonAggressionPacts[a] then NonAggressionPacts[a][b] = nil end
			if NonAggressionPacts[b] then NonAggressionPacts[b][a] = nil end

			if DEBUG then print("NAP EXPIRED: " .. a .. " and " .. b) end

			-- Fire the callback so DiplomacyServer can send global notifications
			if napExpiredCallback then
				task.spawn(napExpiredCallback, a, b)
			end
		end
	end)

	-- Store connection reference for potential cleanup (module-level, not per-player)
	DiplomacyManager._sweepConnection = sweepConnection
end

return DiplomacyManager
