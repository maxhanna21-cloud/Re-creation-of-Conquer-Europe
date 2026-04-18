-- Module: NPCCombatSystem (COUNTRY PERSISTENCE VERSION)
-- NPCs can now be transferred between players when countries change hands
-- Country-owned NPCs (no active player) remain idle until claimed
-- Combat requires tile adjacency - NPCs can only attack enemies on adjacent tiles
-- Uses DiplomacyManager.canAttack() which checks both war AND alliance status
-- Maid-owned lifecycle signals, idempotent registerNPC, ordered unregisterNPC,
-- NPCMovementSystem.OnOwnerChanged wired into transferOwnership

local PathfindingService = game:GetService("PathfindingService")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local DiplomacyManager = require(game.ServerScriptService:WaitForChild("DiplomacyManager", 10))

local Combat = {}

-- Lazy-load TileAdjacencyManager to avoid circular dependency
local TileAdjacencyManager = nil
local function getTileAdjacencyManager()
	if not TileAdjacencyManager then
		TileAdjacencyManager = require(game.ServerScriptService:WaitForChild("TileAdjacencyManager", 10))
	end
	return TileAdjacencyManager
end

-- Lazy-load TileOwnershipManager to avoid circular dependency
local TileOwnershipManager = nil
local function getTileOwnershipManager()
	if not TileOwnershipManager then
		TileOwnershipManager = require(game.ServerScriptService:WaitForChild("TileOwnershipManager", 10))
	end
	return TileOwnershipManager
end

-- Lazy-load NPCMovementSystem to avoid circular dependency
local NPCMovementSystem = nil
local function getNPCMovementSystem()
	if not NPCMovementSystem then
		NPCMovementSystem = require(game.ServerScriptService:WaitForChild("NPCMovementSystem", 10))
	end
	return NPCMovementSystem
end

-- Config
local SHOOT_INTERVAL = 1
local DAMAGE = 10
local BEAM_LIFETIME = 0.1
local LOOP_WAIT = 0.1
local PATH_RECALC_COOLDOWN = 1.0
local DEBUG = true

-- Server Owner folder for server-owned NPCs
local SERVER_OWNER = Instance.new("Folder")
SERVER_OWNER.Name = "ServerOwner"
SERVER_OWNER.Parent = game:GetService("ReplicatedStorage")

-- Internal tables
local npcOwners = {}
local npcRoles = {}
local combatLoops = {}   -- [npcModel] = token (unique table reference per loop instance)
local npcCooldown = {}
local defenderAttackers = {}  -- Tracks who is attacking each Defender
local attackerThreats = {}    -- Tracks who is attacking each Attacker (for auto-retaliation)
local pathTimestamps = {}
local debugParts = {}
local npcInCombat = {}  -- npcModel -> bool: tracks active combat state for Health script management

-- Manual targets: stores a LIST of targets for each attacker
-- manualTargets[npcModel] = { targetModel1, targetModel2, ... }
local manualTargets = {}

-- Per-NPC runtime state bag, owns all lifecycle signals via the Maid.
-- npcRuntime[npcModel] = { maid = Maid }
local npcRuntime = {}

---------------------------------------------------
-- Private: Lightweight Maid / Janitor
-- Owns per-NPC signals and cleanup callbacks.
-- DoCleaning() disconnects all connections, calls all callbacks, then clears the task list.
---------------------------------------------------

local function newMaid()
	local maid = { _tasks = {} }

	function maid:Give(task)
		table.insert(self._tasks, task)
		return task
	end

	function maid:DoCleaning()
		for _, task in ipairs(self._tasks) do
			if typeof(task) == "RBXScriptConnection" then
				task:Disconnect()
			elseif typeof(task) == "function" then
				task()
			elseif typeof(task) == "Instance" then
				task:Destroy()
			end
		end
		table.clear(self._tasks)
	end

	return maid
end

---------------------------------------------------
-- Utilities
---------------------------------------------------

local function getRootPart(model)
	if not model then return nil end
	return model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Torso") or model.PrimaryPart
end

local function cleanupDebugParts(modelName)
	if not DEBUG then return end

	local targetKey = modelName .. "_Target"
	if debugParts[targetKey] then
		debugParts[targetKey]:Destroy()
		debugParts[targetKey] = nil
	end

	for key, part in pairs(debugParts) do
		if string.find(key, modelName .. "_Path_") then
			if part and part.Parent then
				part:Destroy()
			end
			debugParts[key] = nil
		end
	end
end

-- Register Humanoid.Died cleanup through the NPC's maid so there is no hidden ownership.
local function setupDeathCleanup(npcModel, maid)
	local humanoid = npcModel:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	maid:Give(humanoid.Died:Once(function()
		Combat.clearAllManualTargets(npcModel)
		Combat.unregisterNPC(npcModel)
		Debris:AddItem(npcModel, 0.5)
	end))
end

-- Enable or disable the Health regeneration script inside an NPC model
local function setHealthScriptEnabled(npcModel, enabled)
	if not npcModel then return end
	local healthScript = npcModel:FindFirstChild("Health", true)
	if healthScript and (healthScript:IsA("Script") or healthScript:IsA("LocalScript")) then
		healthScript.Enabled = enabled
		if DEBUG then
			print("[Combat] Health script " .. (enabled and "enabled" or "disabled") .. " for " .. npcModel.Name)
		end
	end
end

-- Update the NPC's combat state and manage its Health script accordingly.
-- Called each combat-loop iteration with the current count of valid targets.
local function updateCombatHealthState(npcModel, inCombat)
	if npcInCombat[npcModel] == inCombat then return end  -- State unchanged; skip
	npcInCombat[npcModel] = inCombat
	if inCombat then
		-- Entering combat: always disable the Health script
		setHealthScriptEnabled(npcModel, false)
	else
		-- Leaving combat: re-enable Health only when the NPC is also not moving
		local isMoving = npcModel:GetAttribute("IsMoving") == true
		if not isMoving then
			setHealthScriptEnabled(npcModel, true)
		end
	end
end

local function drawDebugLine(name, startPos, endPos, color, lifetime)
	if not DEBUG then return end

	local distance = (endPos - startPos).Magnitude
	local beam = debugParts[name]
	if not beam or not beam.Parent then
		beam = Instance.new("Part")
		debugParts[name] = beam
	end

	beam.Name = name
	beam.Anchored = true
	beam.CanCollide = false
	beam.CastShadow = false
	beam.Material = Enum.Material.Neon
	beam.Color = color
	beam.Size = Vector3.new(0.2, 0.2, distance)
	beam.CFrame = CFrame.lookAt(startPos, endPos) * CFrame.new(0, 0, -distance / 2)

	if not beam.Parent then
		beam.Parent = workspace
	end

	if lifetime then
		task.delay(lifetime, function()
			if debugParts[name] == beam then
				debugParts[name] = nil
			end
		end)
		Debris:AddItem(beam, lifetime)
	end

	return beam
end

local function createLaserBeam(originPos, targetPos, color)
	local distance = (targetPos - originPos).Magnitude
	local beam = Instance.new("Part")
	beam.Anchored = true
	beam.CanCollide = false
	beam.CastShadow = false
	beam.Material = Enum.Material.Neon
	beam.Color = color or Color3.fromRGB(255, 0, 0)
	beam.Size = Vector3.new(0.2, 0.2, distance)
	beam.CFrame = CFrame.lookAt(originPos, targetPos) * CFrame.new(0, 0, -distance / 2)
	beam.Parent = workspace
	Debris:AddItem(beam, BEAM_LIFETIME)
end

-- Multi-target fire with split damage
local function fireMultiLaser(npcModel, targetHumanoids, beamColor)
	if not npcModel or #targetHumanoids == 0 then return end

	local npcRoot = getRootPart(npcModel)
	if not npcRoot then return end

	-- Split damage evenly among all targets
	local damagePerTarget = DAMAGE / #targetHumanoids

	for _, targetHumanoid in ipairs(targetHumanoids) do
		if targetHumanoid and targetHumanoid.Health > 0 then
			local targetRoot = getRootPart(targetHumanoid.Parent)
			if targetRoot then
				createLaserBeam(npcRoot.Position, targetRoot.Position, beamColor)
				targetHumanoid:TakeDamage(damagePerTarget)
				-- Auto-retaliation: notify target it was hit (only triggers for AutoRetaliate NPCs)
				local targetNpcModel = targetHumanoid.Parent
				if targetNpcModel then
					Combat.noteHit(npcModel, targetNpcModel)
				end
				if DEBUG then
					print(npcModel.Name, "SPLIT FIRE at", targetHumanoid.Parent.Name, "for", string.format("%.2f", damagePerTarget), "damage")
				end
			end
		end
	end
end

local function visualizePath(path, modelName)
	if not DEBUG then return end

	for key, part in pairs(debugParts) do
		if string.find(key, modelName .. "_Path_") then
			if part and part.Parent then
				part:Destroy()
			end
			debugParts[key] = nil
		end
	end

	local waypoints = path:GetWaypoints()
	for i = 1, #waypoints - 1 do
		local startPos = waypoints[i].Position
		local endPos = waypoints[i+1].Position
		drawDebugLine(modelName .. "_Path_" .. i, startPos, endPos, Color3.fromRGB(255, 255, 0), PATH_RECALC_COOLDOWN + 0.1)
	end
end

-- Helper to check if NPC has an active player owner
local function hasActivePlayerOwner(npcModel)
	local currentOwner = Combat.getOwner(npcModel)
	return currentOwner and typeof(currentOwner) == "Instance" and currentOwner:IsA("Player") and currentOwner.Parent
end

-- Check if two NPCs are on adjacent tiles
local function areNPCsOnAdjacentTiles(npcA, npcB)
	local TAM = getTileAdjacencyManager()
	return TAM.canNPCsInteract(npcA, npcB)
end

---------------------------------------------------
-- Combat Loops
-- Each loop instance is identified by a unique token stored in combatLoops[npcModel].
-- The loop exits when the token changes (re-registration) or when the NPC dies/is removed.
---------------------------------------------------

-- Shared combat loop for both Attackers and Defenders (multi-target with split damage + adjacency check).
-- beamColor distinguishes the role visually (red for Attackers, blue for Defenders).
local function startCombatLoop(npcModel, getAllTargets, beamColor)
	if not npcModel then return end
	if combatLoops[npcModel] then return end

	-- Use a unique table reference as a generation token.
	-- When re-registration nils combatLoops[npcModel], this loop detects the token mismatch and exits.
	local token = {}
	combatLoops[npcModel] = token

	task.spawn(function()
		local humanoid = npcModel:FindFirstChildOfClass("Humanoid")

		while combatLoops[npcModel] == token and npcModel.Parent and humanoid and humanoid.Health > 0 do
			local now = os.clock()

			local allTargets = getAllTargets()

			-- Sync Health script with current combat state
			updateCombatHealthState(npcModel, #allTargets > 0)

			-- Only go idle if country-owned AND no targets/threats
			if not hasActivePlayerOwner(npcModel) and #allTargets == 0 then
				local root = getRootPart(npcModel)
				if root then
					humanoid:MoveTo(root.Position)
				end
				task.wait(LOOP_WAIT)
				continue
			end

			if #allTargets > 0 then
				local npcRoot = getRootPart(npcModel)

				if npcRoot then
					-- Stop movement
					humanoid:MoveTo(npcRoot.Position)

					-- Face the first target
					local firstTarget = allTargets[1]
					if firstTarget and firstTarget.Parent then
						local targetRoot = getRootPart(firstTarget.Parent)
						if targetRoot then
							local targetPos = targetRoot.Position
							local selfPos = npcRoot.Position
							local lookAtCFrame = CFrame.lookAt(
								selfPos,
								Vector3.new(targetPos.X, selfPos.Y, targetPos.Z)
							)
							npcRoot.CFrame = CFrame.new(npcRoot.CFrame.Position) * (lookAtCFrame - lookAtCFrame.Position)
						end
					end

					-- Fire at all targets with split damage
					if #allTargets > 0 then
						local lastShot = npcCooldown[npcModel] or 0
						if now - lastShot >= SHOOT_INTERVAL then
							fireMultiLaser(npcModel, allTargets, beamColor)
							npcCooldown[npcModel] = now
						end
					end
				end
			else
				-- No targets - idle
				if DEBUG then
					local targetKey = npcModel.Name .. "_Target"
					if debugParts[targetKey] then
						debugParts[targetKey]:Destroy()
						debugParts[targetKey] = nil
					end
				end
				local root = getRootPart(npcModel)
				if root then
					humanoid:MoveTo(root.Position)
				end
			end

			task.wait(LOOP_WAIT)
		end

		-- Only unregister if we are still the active loop instance and the NPC is gone.
		-- Token mismatch means we were superseded by a re-registration — exit silently.
		if combatLoops[npcModel] == token and not npcModel.Parent then
			Combat.unregisterNPC(npcModel)
		end
	end)
end

-- Thin wrapper: starts the combat loop with red beams for Attackers.
local function startAttackerCombatLoop(npcModel, getAllTargets)
	startCombatLoop(npcModel, getAllTargets, Color3.fromRGB(255, 0, 0))
end

-- Thin wrapper: starts the combat loop with blue beams for Defenders.
local function startDefenderCombatLoop(npcModel, getAllTargets)
	startCombatLoop(npcModel, getAllTargets, Color3.fromRGB(0, 150, 255))
end

-- Public API

function Combat.getServerOwner()
	return SERVER_OWNER
end

-- Transfer ownership of an NPC to a new player (or nil for country-owned).
-- Resets movement state via NPCMovementSystem.OnOwnerChanged.
function Combat.transferOwnership(npcModel, newOwner)
	if not npcModel then return false end

	local oldOwner = npcOwners[npcModel]
	npcOwners[npcModel] = newOwner

	-- Clear manual targets when ownership changes
	Combat.clearAllManualTargets(npcModel)

	-- Clear from defender/attacker threat lists (this NPC's own lists)
	defenderAttackers[npcModel] = nil
	attackerThreats[npcModel] = nil

	-- FIX: Also remove this NPC from OTHER NPCs' target/threat lists
	-- This prevents combat bugs when ownership changes
	for otherNPC, targets in pairs(manualTargets) do
		for i = #targets, 1, -1 do
			if targets[i] == npcModel then
				table.remove(targets, i)
			end
		end
	end

	for defender, attackers in pairs(defenderAttackers) do
		for i = #attackers, 1, -1 do
			if attackers[i] == npcModel then
				table.remove(attackers, i)
			end
		end
	end

	for attacker, threats in pairs(attackerThreats) do
		for i = #threats, 1, -1 do
			if threats[i] == npcModel then
				table.remove(threats, i)
			end
		end
	end

	-- Reset movement state after ownership change so the NPC cannot retain:
	-- active movement monitor, stale reservation, retreat state, or stale IsMoving.
	local moveSystem = getNPCMovementSystem()
	if moveSystem and moveSystem.OnOwnerChanged then
		moveSystem.OnOwnerChanged(npcModel)
	end

	if DEBUG then
		local oldName = oldOwner and (typeof(oldOwner) == "Instance" and oldOwner.Name or "Unknown") or "None"
		local newName = newOwner and (typeof(newOwner) == "Instance" and newOwner.Name or "Unknown") or "Country-Owned"
		print("[Combat] Transferred " .. npcModel.Name .. " from " .. oldName .. " to " .. newName)
	end

	return true
end

-- Add a target to an attacker's target list
function Combat.addManualTarget(attackerModel, targetModel)
	if not attackerModel or not targetModel then return false end

	if not manualTargets[attackerModel] then
		manualTargets[attackerModel] = {}
	end

	-- Check for duplicates
	for _, existing in ipairs(manualTargets[attackerModel]) do
		if existing == targetModel then
			if DEBUG then
				print("[Combat] " .. targetModel.Name .. " already in " .. attackerModel.Name .. "'s target list")
			end
			return false -- Already targeting
		end
	end

	table.insert(manualTargets[attackerModel], targetModel)

	if DEBUG then
		print("[Combat] " .. attackerModel.Name .. " now targeting " .. #manualTargets[attackerModel] .. " enemy(s)")
	end

	return true -- Successfully added
end

-- Remove a specific target from an attacker's target list
function Combat.removeManualTarget(attackerModel, targetModel)
	if not attackerModel or not targetModel then return false end

	local targets = manualTargets[attackerModel]
	if not targets then return false end

	for i, existing in ipairs(targets) do
		if existing == targetModel then
			table.remove(targets, i)

			-- Reciprocal cleanup: remove attackerModel from the target's tracking list
			local targetRole = npcRoles[targetModel]
			if targetRole == "Defender" then
				Combat.removeAttackerFromDefender(attackerModel, targetModel)
			elseif targetRole == "Attacker" then
				Combat.removeThreatFromAttacker(attackerModel, targetModel)
			end

			if DEBUG then
				print("[Combat] " .. targetModel.Name .. " removed from " .. attackerModel.Name .. "'s targets")
			end
			return true
		end
	end

	return false
end

-- Clear all manual targets and clean up reciprocal tracking lists
function Combat.clearAllManualTargets(attackerModel)
	if not attackerModel then return end

	local targets = manualTargets[attackerModel]
	if targets then
		for _, target in ipairs(targets) do
			if target then
				local targetRole = npcRoles[target]
				if targetRole == "Defender" then
					Combat.removeAttackerFromDefender(attackerModel, target)
				elseif targetRole == "Attacker" then
					Combat.removeThreatFromAttacker(attackerModel, target)
				end
			end
		end
	end

	manualTargets[attackerModel] = nil
end

-- Get all manual targets for an attacker
function Combat.getManualTargets(attackerModel)
	return manualTargets[attackerModel] or {}
end

-- Get count of manual targets
function Combat.getManualTargetCount(attackerModel)
	local targets = manualTargets[attackerModel]
	return targets and #targets or 0
end

-- LEGACY: For backwards compatibility (sets single target, clearing others)
function Combat.setManualTarget(attackerModel, targetModel)
	Combat.clearAllManualTargets(attackerModel)
	if targetModel then
		Combat.addManualTarget(attackerModel, targetModel)
	end
end

-- LEGACY: Get first manual target (for backwards compatibility)
function Combat.getManualTarget(attackerModel)
	local targets = manualTargets[attackerModel]
	return targets and targets[1] or nil
end

-- LEGACY: Clear manual target
function Combat.clearManualTarget(attackerModel)
	Combat.clearAllManualTargets(attackerModel)
end

-- Register an NPC with the combat system.
-- Idempotent: calling this on an already-registered NPC cleans the old maid first,
-- then creates a fresh maid and re-registers all signals. No duplicate callbacks.
function Combat.registerNPC(npcModel, ownerPlayer, role)
	if not npcModel or not role then return end

	-- Idempotency: if already registered, clean the old lifecycle signals.
	-- This clears old Destroying and Died connections but does NOT nil the combat tables —
	-- the NPC is alive and should retain its external targeting state.
	if npcRuntime[npcModel] then
		npcRuntime[npcModel].maid:DoCleaning()
		npcRuntime[npcModel] = nil
		-- Nil the loop token so startAttackerCombatLoop / startDefenderCombatLoop can run fresh.
		-- The old loop will detect the token mismatch on its next iteration and exit cleanly.
		combatLoops[npcModel] = nil
	end

	-- Create fresh maid and runtime bag
	local maid = newMaid()
	npcRuntime[npcModel] = { maid = maid }

	-- Register Destroying through maid (replaces bare .Destroying:Connect)
	maid:Give(npcModel.Destroying:Connect(function()
		Combat.clearAllManualTargets(npcModel)
		Combat.unregisterNPC(npcModel)
	end))

	-- Register Humanoid.Died through maid (replaces setupDeathCleanup's hidden ownership)
	setupDeathCleanup(npcModel, maid)

	-- Update owner/role tables
	npcOwners[npcModel] = ownerPlayer
	npcRoles[npcModel] = role

	if role == "Attacker" then
		-- Attackers use multi-target combat with manually assigned targets + auto-retaliation
		startAttackerCombatLoop(npcModel, function()
			local allValidTargets = {}

			-- Get all manual targets
			local targets = manualTargets[npcModel] or {}

			-- Validate and collect humanoids, remove dead/invalid/non-adjacent targets
			for i = #targets, 1, -1 do
				local target = targets[i]

				if target and target.Parent then
					local targetHumanoid = target:FindFirstChildOfClass("Humanoid")

					-- Check tile adjacency
					local isAdjacent = areNPCsOnAdjacentTiles(npcModel, target)

					-- Use country-based check so country-owned (nil-owner) NPCs are handled correctly
					local canFight = DiplomacyManager.canNPCAttack(npcModel, target)

					if targetHumanoid and targetHumanoid.Health > 0 and canFight and isAdjacent then
						table.insert(allValidTargets, targetHumanoid)
					else
						-- Invalid target (friendly, allied, not at war, dead, or not adjacent), remove it
						table.remove(targets, i)
						if DEBUG then
							local reason = not isAdjacent and "not adjacent" or (not canFight and "not at war/allied" or "invalid")
							print("[Combat] " .. npcModel.Name .. " removed " .. reason .. " manual target")
						end
					end
				else
					-- Target destroyed, remove it
					table.remove(targets, i)
				end
			end

			-- Only include threats for COUNTRY-OWNED attackers (auto-retaliation)
			-- Player-owned attackers should only attack their manual targets
			if not hasActivePlayerOwner(npcModel) then
				local threats = attackerThreats[npcModel] or {}
				for i = #threats, 1, -1 do
					local threat = threats[i]

					if threat and threat.Parent then
						local threatHumanoid = threat:FindFirstChildOfClass("Humanoid")

						-- Check tile adjacency for threats
						local isAdjacent = areNPCsOnAdjacentTiles(npcModel, threat)

						-- Use country-based check so country-owned (nil-owner) NPCs are handled correctly
						local canFight = DiplomacyManager.canNPCAttack(npcModel, threat)

						if threatHumanoid and threatHumanoid.Health > 0 and canFight and isAdjacent then
							-- Check if not already in targets list
							local alreadyTargeted = false
							for _, existing in ipairs(allValidTargets) do
								if existing == threatHumanoid then
									alreadyTargeted = true
									break
								end
							end
							if not alreadyTargeted then
								table.insert(allValidTargets, threatHumanoid)
							end
						else
							-- Invalid threat (not adjacent or other reason), remove it
							table.remove(threats, i)
						end
					else
						-- Threat destroyed, remove it
						table.remove(threats, i)
					end
				end
			end

			return allValidTargets
		end)
	else -- Defender
		-- Defenders use multi-target combat with auto-retaliation
		startDefenderCombatLoop(npcModel, function()
			local allValidTargets = {}

			local attackers = defenderAttackers[npcModel] or {}

			for i = #attackers, 1, -1 do
				local att = attackers[i]

				if att and att.Parent then
					local attHumanoid = att:FindFirstChildOfClass("Humanoid")
					local isAdjacent = areNPCsOnAdjacentTiles(npcModel, att)
					local canFight = DiplomacyManager.canNPCAttack(npcModel, att)
					if attHumanoid and attHumanoid.Health > 0 and canFight and isAdjacent then
						table.insert(allValidTargets, attHumanoid)
					else
						table.remove(attackers, i)
					end
				else
					table.remove(attackers, i)
				end
			end

			return allValidTargets
		end)
	end

	if DEBUG then
		local ownerLabel = ownerPlayer and ownerPlayer.Name or "Country-owned"
		print("Registered NPC:", npcModel.Name, "| Role:", role, "| Owner:", ownerLabel)
	end
end

-- Unregister an NPC from the combat system.
-- Cleanup order is mandatory:
--   Step 1: fetch npcRuntime
--   Step 2: call maid:DoCleaning() BEFORE clearing tables (callbacks may read context)
--   Step 3: nil npcRuntime entry
--   Step 4: clear all cross-NPC target/threat references
--   Step 5: nil all per-NPC combat state tables
-- Idempotent: second call on already-unregistered NPC is safe.
function Combat.unregisterNPC(npcModel)
	if not npcModel then return end

	-- FIX: Early-exit if this NPC was already unregistered (prevents redundant
	-- O(N) scans across all target/threat tables on the second call from
	-- the Died→Destroying double-fire path).
	if not npcRuntime[npcModel] and not npcOwners[npcModel] then
		return
	end

	cleanupDebugParts(npcModel.Name)

	-- Step 1: fetch runtime state
	local runtime = npcRuntime[npcModel]

	-- Step 2: clean maid before clearing tables so any callbacks in DoCleaning can still read state
	if runtime then
		runtime.maid:DoCleaning()
	end

	-- Step 3: nil the runtime entry
	npcRuntime[npcModel] = nil

	-- Step 4: Remove this NPC from all other NPCs' target/threat lists
	for otherNPC, targets in pairs(manualTargets) do
		for i = #targets, 1, -1 do
			if targets[i] == npcModel then
				table.remove(targets, i)
			end
		end
	end

	for defender, attackers in pairs(defenderAttackers) do
		for i = #attackers, 1, -1 do
			if attackers[i] == npcModel then
				table.remove(attackers, i)
			end
		end
	end

	for attacker, threats in pairs(attackerThreats) do
		for i = #threats, 1, -1 do
			if threats[i] == npcModel then
				table.remove(threats, i)
			end
		end
	end

	-- Step 5: clear all per-NPC combat state tables
	manualTargets[npcModel] = nil
	npcOwners[npcModel] = nil
	npcRoles[npcModel] = nil
	npcCooldown[npcModel] = nil
	defenderAttackers[npcModel] = nil
	attackerThreats[npcModel] = nil
	pathTimestamps[npcModel] = nil
	combatLoops[npcModel] = nil
	npcInCombat[npcModel] = nil
end

-- Track when an attacker is targeting a defender (for defender auto-retaliation)
function Combat.noteAttackerTargeting(attackerModel, defenderModel)
	if not attackerModel or not defenderModel then return end
	if not defenderAttackers[defenderModel] then
		defenderAttackers[defenderModel] = {}
	end

	local found = false
	for _, v in ipairs(defenderAttackers[defenderModel]) do
		if v == attackerModel then found = true break end
	end

	if not found then
		table.insert(defenderAttackers[defenderModel], attackerModel)
		if DEBUG then
			print("[Combat] Defender " .. defenderModel.Name .. " now tracking " .. #defenderAttackers[defenderModel] .. " attacker(s)")
		end
	end
end

-- Track when someone is targeting an attacker (for attacker auto-retaliation)
function Combat.noteTargetingAttacker(aggressorModel, victimAttackerModel)
	if not aggressorModel or not victimAttackerModel then return end
	if not attackerThreats[victimAttackerModel] then
		attackerThreats[victimAttackerModel] = {}
	end

	local found = false
	for _, v in ipairs(attackerThreats[victimAttackerModel]) do
		if v == aggressorModel then found = true break end
	end

	if not found then
		table.insert(attackerThreats[victimAttackerModel], aggressorModel)
		if DEBUG then
			print("[Combat] Attacker " .. victimAttackerModel.Name .. " now tracking " .. #attackerThreats[victimAttackerModel] .. " threat(s)")
		end
	end
end

-- Record that attackerNpc hit targetNpc.
-- Disengage logic applies to ALL AttackerNPCs (player-owned and country-owned).
-- Auto-retaliation (threat tracking) only applies to NPCs with AutoRetaliate=true.
function Combat.noteHit(attackerNpc, targetNpc)
	if not attackerNpc or not targetNpc then return end
	if targetNpc:GetAttribute("Dead") then return end

	local targetRole = npcRoles[targetNpc]

	-- When any AttackerNPC is hit by an enemy that it is NOT already
	-- manually targeting, it disengages from all current manual targets
	-- so it stops its offensive. This applies to ALL AttackerNPCs.
	-- Only manualTargets is checked (not attackerThreats), because threats
	-- are registered early via handleSecondClick before combat even starts.
	if targetRole == "Attacker" then
		local alreadyTargeting = false

		local targets = manualTargets[targetNpc]
		if targets then
			for _, t in ipairs(targets) do
				if t == attackerNpc then
					alreadyTargeting = true
					break
				end
			end
		end

		if not alreadyTargeting then
			Combat.clearAllManualTargets(targetNpc)
			if DEBUG then
				print("[Combat] " .. targetNpc.Name .. " disengaged from manual targets after being attacked by " .. attackerNpc.Name)
			end
		end
	end

	-- Auto-retaliation threat tracking only for AutoRetaliate NPCs (country-owned)
	if targetNpc:GetAttribute("AutoRetaliate") ~= true then return end

	if targetRole == "Defender" then
		Combat.noteAttackerTargeting(attackerNpc, targetNpc)
	elseif targetRole == "Attacker" then
		Combat.noteTargetingAttacker(attackerNpc, targetNpc)
	end
end

function Combat.removeAttackerFromDefender(attackerModel, defenderModel)
	if not attackerModel or not defenderModel then return end
	local attackers = defenderAttackers[defenderModel]
	if not attackers then return end

	for i, att in ipairs(attackers) do
		if att == attackerModel then
			table.remove(attackers, i)
			if DEBUG then
				print("[Combat] " .. attackerModel.Name .. " removed from " .. defenderModel.Name .. "'s threat list")
			end
			break
		end
	end
end

-- Remove a threat from an attacker's threat list
function Combat.removeThreatFromAttacker(threatModel, attackerModel)
	if not threatModel or not attackerModel then return end
	local threats = attackerThreats[attackerModel]
	if not threats then return end

	for i, threat in ipairs(threats) do
		if threat == threatModel then
			table.remove(threats, i)
			if DEBUG then
				print("[Combat] " .. threatModel.Name .. " removed from " .. attackerModel.Name .. "'s threat list")
			end
			break
		end
	end
end

function Combat.attackAttacker(attackerModel, targetAttackerModel)
	if not attackerModel or not targetAttackerModel then return end
	if not npcOwners[attackerModel] then return end

	-- Use country-based check so country-owned (nil-owner) NPCs are handled correctly
	if not DiplomacyManager.canNPCAttack(attackerModel, targetAttackerModel) then
		return -- Can't attack (same country, allied, or not at war)
	end

	Combat.addManualTarget(attackerModel, targetAttackerModel)
end

-- Helpers
function Combat.getOwner(npc) return npcOwners[npc] end
function Combat.getRole(npc) return npcRoles[npc] end
function Combat.isLoopRunning(npc) return combatLoops[npc] ~= nil end

-- Returns true when the NPC currently has active combat targets or is being attacked.
-- Used by NPCMovementSystem and NPCTargetingHandler to block/gate movement.
function Combat.isInCombat(npc)
	return npcInCombat[npc] == true
end

function Combat.getAttackerCount(defenderModel)
	local attackers = defenderAttackers[defenderModel]
	return attackers and #attackers or 0
end

-- Get threat count for an attacker
function Combat.getThreatCount(attackerModel)
	local threats = attackerThreats[attackerModel]
	return threats and #threats or 0
end

return Combat

