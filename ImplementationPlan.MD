# V1 NPC Retreat & Recovery System — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current "fight to the death" NPC behavior with a health-threshold-triggered retreat system where NPCs disengage combat, walk to a safe adjacent friendly tile (invulnerable during transit), then enter a vulnerable recovery state (skull GUI visible) until healed past a recovery threshold.

**Architecture:** The combat system (NPCCombatSystem) owns retreat decisions via `tryTriggerRetreat()`, called each combat loop tick. The movement system (NPCMovementSystem) owns pathing via `startHealthRetreat()`. They coordinate through a module-level `OnRetreatArrived(npcModel)` callback. A `RetreatState` attribute on each NPC model (`"None"` / `"Retreating"` / `"Recovering"`) is the authoritative gameplay state for attack blocking, skull GUI, and vulnerability rules. Movement-system internal state (`movementStates[npc].state`) remains independent — the two never overwrite each other.

**Tech Stack:** Roblox Luau, ModuleScripts under `src/shared/` and `src/server/`

**Line number caveat:** All line numbers in this plan are approximate (±1–3 lines) based on the file state at time of writing. Agentic workers should locate insertion points by **anchor patterns** (function names, unique code strings, comments) rather than relying on exact line numbers. Each step includes the relevant anchor alongside the line number.

**User Clarification:** Moving a Recovering NPC cancels the recovery state lock (RetreatState → "None") but the skull GUI persists until health crosses RECOVERY_THRESHOLD. While the skull is showing (`SkullActive` attribute = `true`), the NPC can **defend** (auto-retaliate when attacked) but **cannot initiate attacks** (no manual targeting). The `SkullActive` attribute tracks the skull independently from `RetreatState` so the attack block survives movement-cancels-recovery. The HealthChanged listener stays connected and clears both the skull and `SkullActive` when the threshold is reached.

**Auto-retaliation vs retreat clarification:** For Defenders, auto-retaliation still follows the existing `AutoRetaliate` rule. Player-owned Defenders (`AutoRetaliate ~= true`) can retreat when attacked via `defenderRetreatThreats`, but they do **not** auto-retaliate — only country-owned Defenders (`AutoRetaliate == true`) both retreat and auto-retaliate. Player-owned Attackers can defend via `attackerThreats` (which is populated for all Attackers regardless of `AutoRetaliate`).

---

## File Structure

| File | Changes |
|------|---------|
| `src/shared/NPCCombatSystem.lua` | Add constants, data tables, reservation helpers. Add `tryTriggerRetreat()`, `disengageForRetreat()`, `cleanupRetreatState()`. Wire `OnRetreatArrived` callback. Add combat loop skip guard + retreat trigger. Add attack guards and invulnerability filters. Add cleanup calls in `unregisterNPC` and `transferOwnership`. |
| `src/shared/NPCMovementSystem.lua` | Add `startHealthRetreat()`, `cancelHealthRetreat()`. Modify `monitorMovement()` for health retreat arrival and stuck fallback. Add movement-cancels-recovery logic in `startMovement()`. |
| `src/server/NPCTargetingHandler.server.lua` | Add RetreatState guard in `handleSecondClick()` for the attacker. |
| `src/server/NPCSpawner.lua` | Initialize `RetreatState = "None"` on spawn. Call `Combat.cleanupRetreatState()` in cleanup pipeline. |

---

## Task 1: Foundation — Constants, Data Structures, Helpers

**Files:**
- Modify: `src/shared/NPCCombatSystem.lua`
- Modify: `src/server/NPCSpawner.lua`

- [ ] **Step 0: Add forward declaration for handleRetreatArrival**

Insert **before** the `getNPCMovementSystem` lazy loader (before `local NPCMovementSystem = nil`, around line 39). This MUST appear before the closure that references it, otherwise Luau resolves it as a global `nil`:

```lua
-- Forward declaration: body assigned in Task 4 Step 1.
-- Must appear before getNPCMovementSystem() so the lazy-loader closure captures this local.
local handleRetreatArrival
```

- [ ] **Step 1: Add TileManager lazy loader to NPCCombatSystem**

Insert after the NPCMovementSystem lazy loader block (after line 48):

```lua
-- Lazy-load TileManager to avoid circular dependency
local TileManager = nil
local function getTileManager()
	if not TileManager then
		TileManager = require(game.ServerScriptService:WaitForChild("TileManager", 10))
	end
	return TileManager
end
```

- [ ] **Step 2: Fix TileOwnershipManager lazy loader name**

At line 34, change `local function _getTileOwnershipManager()` to `local function getTileOwnershipManager()` (remove underscore prefix so it can be called).

- [ ] **Step 3: Add retreat constants**

Insert after the existing config block (after line 56, after `local DEBUG = true`):

```lua
-- Retreat/Recovery constants
local RETREAT_THRESHOLD = 0.30
local RECOVERY_THRESHOLD = 0.55
```

- [ ] **Step 4: Add retreat data tables**

Insert after the `npcRuntime` table declaration (after line 80):

```lua
-- Retreat system tables
local reservedRetreatTiles = {}   -- [tileId] = npcModel
local npcReservedTile = {}        -- [npcModel] = tileId
local recoveryConnections = {}    -- [npcModel] = RBXScriptConnection
local defenderRetreatThreats = {} -- [defenderNpc] = { attackerNpc, ... } (retreat-only tracking)
```

- [ ] **Step 5: Add centralized reservation helpers**

Insert after the retreat data tables:

```lua
local function reserveRetreatTile(npcModel, tileId)
	reservedRetreatTiles[tileId] = npcModel
	npcReservedTile[npcModel] = tileId
end

local function releaseRetreatReservation(npcModel)
	local tileId = npcReservedTile[npcModel]
	if tileId then
		reservedRetreatTiles[tileId] = nil
	end
	npcReservedTile[npcModel] = nil
end
```

- [ ] **Step 5b: Add defenderRetreatThreats helpers and reciprocal cleanup**

Insert after the reservation helpers. These must exist before `tryTriggerRetreat` (Task 5) which calls `getDefenderRetreatThreatCount`:

```lua
function Combat.noteDefenderRetreatThreat(attackerNpc, defenderNpc)
	if not defenderRetreatThreats[defenderNpc] then
		defenderRetreatThreats[defenderNpc] = {}
	end
	for _, existing in ipairs(defenderRetreatThreats[defenderNpc]) do
		if existing == attackerNpc then return end
	end
	table.insert(defenderRetreatThreats[defenderNpc], attackerNpc)
end

function Combat.getDefenderRetreatThreatCount(npcModel)
	local threats = defenderRetreatThreats[npcModel]
	if not threats then return 0 end
	-- Prune dead/destroyed attackers before counting
	for i = #threats, 1, -1 do
		local threat = threats[i]
		local humanoid = threat and threat:FindFirstChildOfClass("Humanoid")
		if not threat or not threat.Parent or not humanoid or humanoid.Health <= 0 then
			table.remove(threats, i)
		end
	end
	if #threats == 0 then
		defenderRetreatThreats[npcModel] = nil
		return 0
	end
	return #threats
end

-- Reciprocal cleanup: remove an NPC from ALL defenders' retreat threat lists.
-- Called when an attacker dies, retreats, transfers ownership, or is unregistered.
local function removeNPCFromDefenderRetreatThreats(npcModel)
	for defender, threats in pairs(defenderRetreatThreats) do
		for i = #threats, 1, -1 do
			if threats[i] == npcModel then
				table.remove(threats, i)
			end
		end
		if #threats == 0 then
			defenderRetreatThreats[defender] = nil
		end
	end
end
```

- [ ] **Step 6: Add cleanupRetreatState public function**

Insert immediately before the final `return Combat` statement at the bottom of the file. This is the public API for external cleanup — idempotent, safe to call multiple times:

```lua
function Combat.cleanupRetreatState(npcModel)
	if not npcModel then return end

	releaseRetreatReservation(npcModel)
	defenderRetreatThreats[npcModel] = nil
	removeNPCFromDefenderRetreatThreats(npcModel)

	if recoveryConnections[npcModel] then
		recoveryConnections[npcModel]:Disconnect()
		recoveryConnections[npcModel] = nil
	end

	-- Hide skull GUI and clear SkullActive
	local skull = npcModel:FindFirstChild("SkullGui", true)
	if skull and skull:IsA("BillboardGui") then
		skull.Enabled = false
	end
	npcModel:SetAttribute("SkullActive", nil)

	if npcModel:GetAttribute("RetreatState") ~= nil then
		npcModel:SetAttribute("RetreatState", "None")
	end
end
```

- [ ] **Step 7: Initialize RetreatState in NPCSpawner**

In `src/server/NPCSpawner.lua`, after the `AutoRetaliate` attribute block (after line 103, after the `if not ownerPlayer then ... end` block), add:

```lua
	-- Initialize retreat state
	npcClone:SetAttribute("RetreatState", "None")
```

- [ ] **Step 8: Commit**

```bash
git add src/shared/NPCCombatSystem.lua src/server/NPCSpawner.lua
git commit -m "feat(retreat): add foundation constants, tables, helpers, and RetreatState init"
```

---

## Task 2: Combat.disengageForRetreat()

**Files:**
- Modify: `src/shared/NPCCombatSystem.lua`

- [ ] **Step 1: Implement disengageForRetreat**

Insert before `Combat.cleanupRetreatState` (before the function added in Task 1 Step 6):

```lua
function Combat.disengageForRetreat(npcModel)
	if not npcModel then return end

	-- 1. Clear this NPC's manual targets (with reciprocal cleanup).
	-- clearAllManualTargets already removes the NPC from other NPCs'
	-- defenderAttackers entries, so no separate loop is needed.
	Combat.clearAllManualTargets(npcModel)

	-- 2. Clear this NPC's own threat/attacker lists + retreat threats
	defenderAttackers[npcModel] = nil
	attackerThreats[npcModel] = nil
	defenderRetreatThreats[npcModel] = nil
	removeNPCFromDefenderRetreatThreats(npcModel)

	-- 3. Clear combat state
	npcInCombat[npcModel] = false

	-- 4. Stop active beam/laser visuals
	cleanupDebugParts(npcModel.Name)

	if DEBUG then
		print("[Combat] " .. npcModel.Name .. " disengaged for retreat")
	end
end
```

- [ ] **Step 2: Commit**

```bash
git add src/shared/NPCCombatSystem.lua
git commit -m "feat(retreat): implement Combat.disengageForRetreat()"
```

---

## Task 3: NPCMovementSystem.startHealthRetreat() + Monitor Modifications

**Files:**
- Modify: `src/shared/NPCMovementSystem.lua`

- [ ] **Step 1: Add OnRetreatArrived callback slot**

At the top of `NPCMovementSystem.lua`, after the `NPCMovementSystem = {}` declaration (after line 15), add:

```lua
-- Module-level callback set by NPCCombatSystem during initialization.
-- Fired exactly once when a health retreat NPC arrives at its retreat tile.
NPCMovementSystem.OnRetreatArrived = nil
```

- [ ] **Step 1b: Add health-retreat flag cleanup helper**

Insert **immediately after** the movement-state table declarations (`local movementStates = {}`, `local activeMovements = {}`, `local reservedTiles = {}`). This helper must be declared after `movementStates` so it captures the local table, not a global:

```lua
local function clearHealthRetreatFlag(npcModel)
	local stateData = movementStates[npcModel]
	if stateData then
		stateData.isHealthRetreat = nil
	end
end
```

- [ ] **Step 2: Modify monitorMovement — health retreat arrival**

In the `monitorMovement` function, replace the retreat arrival block (lines 1330–1334):

```lua
		if isRetreat then
			if DEBUG then print("[NPCMovement] " .. npcModel.Name .. " retreat complete") end
			stopMovement(npcModel, "Idle")
			return
		end
```

with:

```lua
		if isRetreat then
			local stateData = movementStates[npcModel]
			if stateData and stateData.isHealthRetreat and not movement.retreatCallbackFired then
				movement.retreatCallbackFired = true

				getDependencies()
				local targetTilePart = movement.retreatTilePart
				local arrivalTileId = targetTilePart and TileAdjacencyManager.getTileId(targetTilePart)
				local currentOccupant = arrivalTileId and TileManager.getTileOccupantById(arrivalTileId)
				local isOccupiedByOther = currentOccupant ~= nil and currentOccupant ~= npcModel

				if not isOccupiedByOther and targetTilePart then
					local npcCountry = npcModel:GetAttribute("Country")
					local originTileKey = movement.originTileKey
					if originTileKey then
						TileManager.releaseTile(npcCountry, originTileKey)
					end
					TileManager.occupyResolvedTile(npcCountry, targetTilePart, npcModel)
					local targetTileKey = movement.targetTileKey
					npcModel:SetAttribute("TileKey", targetTileKey)
					if arrivalTileId then
						npcModel:SetAttribute("CurrentTileId", arrivalTileId)
					end
				else
					if movement.originPosition then
						npcModel:PivotTo(CFrame.new(movement.originPosition))
						local snapRoot = getRootPart(npcModel)
						if snapRoot then snapRoot.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end
					end
				end

				-- Note: stopMovement() may re-enable the Health script since the NPC
				-- is no longer in combat. This is fine — recovery begins immediately.
				stopMovement(npcModel, "Idle")
				clearHealthRetreatFlag(npcModel)

				if NPCMovementSystem.OnRetreatArrived then
					NPCMovementSystem.OnRetreatArrived(npcModel)
				end
				return
			end

			if DEBUG then print("[NPCMovement] " .. npcModel.Name .. " retreat complete") end
			stopMovement(npcModel, "Idle")
			return
		end
```

- [ ] **Step 3: Modify monitorMovement — health retreat stuck fallback**

In the stuck/exhausted retreat branch (around line 1604–1609), replace:

```lua
			if isRetreat then
				-- if already retreating, teleport directly to origin
				if DEBUG then print("[NPCMovement] Retreat stuck; teleporting", npcModel.Name) end
				teleportToSafeTile(npcModel)
				stopMovement(npcModel, "Idle")
```

with:

```lua
			if isRetreat then
				local stateData = movementStates[npcModel]
				if stateData and stateData.isHealthRetreat and not movement.retreatCallbackFired then
					movement.retreatCallbackFired = true
					if movement.originPosition then
						npcModel:PivotTo(CFrame.new(movement.originPosition))
						local snapRoot = getRootPart(npcModel)
						if snapRoot then snapRoot.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end
					else
						teleportToSafeTile(npcModel)
					end
					stopMovement(npcModel, "Idle")
					clearHealthRetreatFlag(npcModel)
					if NPCMovementSystem.OnRetreatArrived then
						NPCMovementSystem.OnRetreatArrived(npcModel)
					end
				else
					if DEBUG then print("[NPCMovement] Retreat stuck; teleporting", npcModel.Name) end
					teleportToSafeTile(npcModel)
					stopMovement(npcModel, "Idle")
				end
```

- [ ] **Step 4: Implement startHealthRetreat**

Insert after the existing `startRetreat` function (after line 2036), before `cancelMovement`:

```lua
function NPCMovementSystem.startHealthRetreat(npcModel, targetTilePart)
	getDependencies()

	if not npcModel or not targetTilePart then return false, "Invalid parameters" end

	local humanoid = getHumanoid(npcModel)
	local root = getRootPart(npcModel)
	if not humanoid or not root then return false, "NPC missing humanoid or root" end
	if humanoid.Health <= 0 then return false, "NPC is dead" end

	-- Cancel any existing movement
	local existingMovement = activeMovements[npcModel]
	if existingMovement then
		if existingMovement.targetTileKey then
			releaseTileReservation(existingMovement.targetTileKey, npcModel)
		end
		if existingMovement.connection then
			pcall(function() existingMovement.connection:Disconnect() end)
		end
		activeMovements[npcModel] = nil
	end

	-- Resolve current tile
	local currentTileId = npcModel:GetAttribute("CurrentTileId")
	local currentTilePart = currentTileId and TileAdjacencyManager.getTileFromId(currentTileId)
	if not currentTilePart then
		local currentTileKey = npcModel:GetAttribute("TileKey")
		if currentTileKey then
			currentTilePart = TileAdjacencyManager.getTileFromKey(currentTileKey)
		end
	end
	if not currentTilePart then return false, "Cannot resolve current tile" end

	-- Verify adjacency proof exists
	local proof = TileAdjacencyManager.getAdjacencyProof(currentTilePart, targetTilePart)
	if not proof then return false, "No walkable crossing to retreat tile" end

	-- Compute positions
	local targetPosition = getTileSpawnPosition(targetTilePart)
	if not targetPosition then return false, "Cannot compute retreat tile position" end

	local originTileKey = npcModel:GetAttribute("TileKey")
	local originPosition = getTileSpawnPosition(currentTilePart) or root.Position
	local targetTileKey = TileManager.getTileKeyFromPart(targetTilePart)

	-- Build enriched waypoints for the 2-tile path
	local tilePath = { currentTilePart, targetTilePart }
	local enrichedWaypoints = buildEnrichedWaypoints(tilePath, {})

	if not enrichedWaypoints or #enrichedWaypoints < 2 then
		return false, "Failed to build retreat waypoints"
	end

	-- Set movement state
	movementStates[npcModel] = movementStates[npcModel] or {}
	movementStates[npcModel].state = "Retreating"
	movementStates[npcModel].isHealthRetreat = true
	movementStates[npcModel].lastTeleport = movementStates[npcModel].lastTeleport or 0
	movementStates[npcModel].lastSamplePos = root.Position
	movementStates[npcModel].lastSampleTime = os.clock()
	movementStates[npcModel].stuckSince = nil
	movementStates[npcModel].moveAttempts = 0
	movementStates[npcModel].fallRecoveries = 0

	npcModel:SetAttribute("IsMoving", true)
	setNPCHealthScriptEnabled(npcModel, false)

	activeMovements[npcModel] = {
		targetTileKey = targetTileKey,
		originTileKey = originTileKey,
		targetPosition = targetPosition,
		originPosition = originPosition,
		retreatTilePart = targetTilePart,
		enrichedWaypoints = enrichedWaypoints,
		currentWaypoint = 2,
		retreatCallbackFired = false,
		connection = nil,
	}

	-- Start walking
	local firstWaypointPos = enrichedWaypoints[2].position
	if humanoid and firstWaypointPos then
		humanoid:MoveTo(firstWaypointPos)
	end

	-- Monitor movement (isRetreat = true)
	local connection
	connection = RunService.Heartbeat:Connect(function()
		if not npcModel or not npcModel.Parent then
			pcall(function() connection:Disconnect() end)
			return
		end
		monitorMovement(npcModel, true)
	end)
	activeMovements[npcModel].connection = connection

	startGroundCheck(npcModel)

	if DEBUG then
		print("[NPCMovement] " .. npcModel.Name .. " health retreat to " .. (targetTileKey or "unknown"))
	end

	return true
end
```

- [ ] **Step 5: Add cancelHealthRetreat function**

Insert after `startHealthRetreat`. This is the explicit cancellation path called by `Combat.transferOwnership()` (via the lazy-loaded movement-system accessor) when ownership changes during an active health retreat. Without it, `OnOwnerChanged()` returns early for `"Retreating"` movement state, leaving the NPC walking with cleared gameplay state.

```lua
function NPCMovementSystem.cancelHealthRetreat(npcModel)
	if not npcModel then return end
	local stateData = movementStates[npcModel]
	if not stateData or not stateData.isHealthRetreat then return end

	-- Cancel in-flight movement
	local movement = activeMovements[npcModel]
	if movement then
		if movement.targetTileKey then
			releaseTileReservation(movement.targetTileKey, npcModel)
		end
		if movement.connection then
			pcall(function() movement.connection:Disconnect() end)
		end
		activeMovements[npcModel] = nil
	end

	-- Clear movement-side health retreat state
	clearHealthRetreatFlag(npcModel)
	stateData.state = "Idle"

	-- Snap back to origin if mid-walk and stop Humanoid's active MoveTo
	local humanoid = getHumanoid(npcModel)
	local root = getRootPart(npcModel)
	if movement and movement.originPosition then
		npcModel:PivotTo(CFrame.new(movement.originPosition))
		root = getRootPart(npcModel)
		if root then root.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end
	end
	if humanoid then
		local stopPos = root and root.Position or (movement and movement.originPosition)
		if stopPos then
			humanoid:MoveTo(stopPos)
		end
	end

	-- Re-enable health script
	setNPCHealthScriptEnabled(npcModel, true)

	npcModel:SetAttribute("IsMoving", nil)

	if DEBUG then
		print("[NPCMovement] " .. npcModel.Name .. " health retreat cancelled (ownership transfer)")
	end
end
```

**Note on health-script function names:** `NPCMovementSystem` uses `setNPCHealthScriptEnabled` while `NPCCombatSystem` uses `setHealthScriptEnabled`. Both are `local` functions that toggle `npcModel:FindFirstChild("Health", true).Enabled`. This is intentional — each module owns its own helper. If one diverges (adds guards, side effects), consider refactoring to a single canonical path.

- [ ] **Step 6: Commit**

```bash
git add src/shared/NPCMovementSystem.lua
git commit -m "feat(retreat): add startHealthRetreat, cancelHealthRetreat + health retreat monitor paths"
```

---

## Task 4: OnRetreatArrived Callback + Recovery Monitoring

**Files:**
- Modify: `src/shared/NPCCombatSystem.lua`

- [ ] **Step 1: Implement the handleRetreatArrival function**

Insert before `Combat.cleanupRetreatState` in NPCCombatSystem.lua:

```lua
-- Called by NPCMovementSystem when a health-retreating NPC arrives at (or falls back to) its destination.
-- Transitions the NPC into Recovering state: enables regen, shows skull, attaches HealthChanged listener.
handleRetreatArrival = function(npcModel)
	if not npcModel or not npcModel.Parent then
		releaseRetreatReservation(npcModel)
		return
	end

	local humanoid = npcModel:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		releaseRetreatReservation(npcModel)
		if npcModel:GetAttribute("RetreatState") ~= "None" then
			npcModel:SetAttribute("RetreatState", "None")
		end
		return
	end

	if npcModel:GetAttribute("RetreatState") ~= "Retreating" then
		releaseRetreatReservation(npcModel)
		return
	end

	-- Release retreat tile reservation (NPC has arrived)
	releaseRetreatReservation(npcModel)

	-- Transition to Recovering
	npcModel:SetAttribute("RetreatState", "Recovering")

	-- Enable health regen (regen starts now, after arrival)
	setHealthScriptEnabled(npcModel, true)

	-- Show skull GUI and set SkullActive attribute
	local skull = npcModel:FindFirstChild("SkullGui", true)
	if skull and skull:IsA("BillboardGui") then
		skull.Enabled = true
	end
	npcModel:SetAttribute("SkullActive", true)

	-- Re-entrancy guard: disconnect any existing listener before connecting new one
	if recoveryConnections[npcModel] then
		recoveryConnections[npcModel]:Disconnect()
		recoveryConnections[npcModel] = nil
	end

	-- Connect HealthChanged listener for recovery threshold
	recoveryConnections[npcModel] = humanoid.HealthChanged:Connect(function(newHealth)
		if humanoid.MaxHealth <= 0 then return end
		if newHealth / humanoid.MaxHealth > RECOVERY_THRESHOLD then
			-- Recovery complete
			if npcModel:GetAttribute("RetreatState") == "Recovering" then
				npcModel:SetAttribute("RetreatState", "None")
			end

			-- Hide skull GUI and clear SkullActive
			local skullGui = npcModel:FindFirstChild("SkullGui", true)
			if skullGui and skullGui:IsA("BillboardGui") then
				skullGui.Enabled = false
			end
			npcModel:SetAttribute("SkullActive", nil)

			-- Disconnect this listener
			if recoveryConnections[npcModel] then
				recoveryConnections[npcModel]:Disconnect()
				recoveryConnections[npcModel] = nil
			end

			if DEBUG then
				print("[Combat] " .. npcModel.Name .. " recovered — skull removed, fully operational")
			end
		end
	end)

	if DEBUG then
		print("[Combat] " .. npcModel.Name .. " entered Recovering state — skull visible, regen started")
	end
end
```

- [ ] **Step 2: Wire the callback into NPCMovementSystem**

Modify the `getNPCMovementSystem` lazy loader (around line 42–48) to set the `OnRetreatArrived` callback on first load:

```lua
local retreatCallbackWired = false
local NPCMovementSystem = nil
local function getNPCMovementSystem()
	if not NPCMovementSystem then
		NPCMovementSystem = require(game.ServerScriptService:WaitForChild("NPCMovementSystem", 10))
	end
	if not retreatCallbackWired then
		retreatCallbackWired = true
		NPCMovementSystem.OnRetreatArrived = handleRetreatArrival
	end
	return NPCMovementSystem
end
```

Note: the `local retreatCallbackWired = false` line goes BEFORE the `local NPCMovementSystem = nil` line. Move the existing `local NPCMovementSystem = nil` to after the new flag declaration.

- [ ] **Step 3: Commit**

```bash
git add src/shared/NPCCombatSystem.lua
git commit -m "feat(retreat): implement OnRetreatArrived callback + recovery monitoring"
```

---

## Task 5: Combat.tryTriggerRetreat() — Tile Selection + Orchestration

**Files:**
- Modify: `src/shared/NPCCombatSystem.lua`

- [ ] **Step 1: Implement tryTriggerRetreat**

Insert before `Combat.disengageForRetreat` in NPCCombatSystem.lua:

```lua
function Combat.tryTriggerRetreat(npcModel)
	if not npcModel or not npcModel.Parent then return false end

	-- Precondition 1: alive
	local humanoid = npcModel:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return false end

	-- Precondition 2: not already retreating/recovering (gameplay state)
	local retreatState = npcModel:GetAttribute("RetreatState")
	if retreatState ~= "None" then return false end

	-- Precondition 2b: not retreating at movement level (desync guard)
	local moveSystem = getNPCMovementSystem()
	if moveSystem.isRetreating(npcModel) then return false end

	-- Precondition 3: health below threshold
	if humanoid.MaxHealth <= 0 then return false end
	if humanoid.Health / humanoid.MaxHealth >= RETREAT_THRESHOLD then return false end

	-- Precondition 4: being attacked (not merely initiating)
	local role = npcRoles[npcModel]
	if role == "Defender" then
		if Combat.getDefenderRetreatThreatCount(npcModel) <= 0 then return false end
	elseif role == "Attacker" then
		if Combat.getThreatCount(npcModel) <= 0 then
			-- Not being attacked, but at low health while attacking:
			-- halt the attack to avoid fighting to death (clear targets, stop combat)
			local targets = manualTargets[npcModel]
			if targets and #targets > 0 then
				Combat.clearAllManualTargets(npcModel)
				if DEBUG then
					print("[Combat] " .. npcModel.Name .. " halted attack at low health (no threats, disengaging)")
				end
			end
			return false
		end
	else
		return false
	end

	-- Generate retreat candidates
	local TAM = getTileAdjacencyManager()
	local TOM = getTileOwnershipManager()
	local TM = getTileManager()
	local DM = getDiplomacyManager()

	local currentTileId = npcModel:GetAttribute("CurrentTileId")
	local currentTilePart = currentTileId and TAM.getTileFromId(currentTileId)
	if not currentTilePart then return false end

	local npcCountry = npcModel:GetAttribute("Country")
	if not npcCountry then return false end

	local adjacentTiles = TAM.getAdjacentTiles(currentTilePart)
	if not adjacentTiles or #adjacentTiles == 0 then
		if DEBUG then
			print("[Combat] " .. npcModel.Name .. " retreat impossible — no adjacent tiles, killing NPC")
		end
		humanoid.Health = 0
		return false
	end

	-- Filter to friendly-owned tiles, exclude current tile, exclude occupied/reserved
	local candidates = {}
	for _, candidatePart in ipairs(adjacentTiles) do
		if candidatePart ~= currentTilePart then
			local isFriendly = TOM.tileEffectivelyBelongsTo(candidatePart, npcCountry)
			if isFriendly then
				local candTileId = TAM.getTileId(candidatePart)
				if candTileId then
					local isOccupied = TM.isTileOccupiedById(candTileId)
					local isReserved = reservedRetreatTiles[candTileId] ~= nil
					if not isOccupied and not isReserved then
						table.insert(candidates, { part = candidatePart, tileId = candTileId })
					end
				end
			end
		end
	end

	if #candidates == 0 then
		if DEBUG then
			print("[Combat] " .. npcModel.Name .. " retreat impossible — no valid candidates, killing NPC")
		end
		humanoid.Health = 0
		return false
	end

	-- Score candidates: distance from enemies on tiles adjacent to CURRENT tile.
	-- Note: this heuristic only considers enemies near the NPC's current position,
	-- not enemies adjacent to each candidate tile. A candidate far from current-tile
	-- enemies might be adjacent to unchecked enemies. Acceptable for V1 since the
	-- NPC still retreats to a valid friendly tile; improve if playtesting reveals issues.
	-- Find enemy NPCs on adjacent tiles
	local enemyPositions = {}
	for _, adjPart in ipairs(adjacentTiles) do
		local adjTileId = TAM.getTileId(adjPart)
		if adjTileId then
			local occupant = TM.getTileOccupantById(adjTileId)
			if occupant and occupant ~= npcModel and occupant.Parent then
				local occupantCountry = occupant:GetAttribute("Country")
				if occupantCountry and occupantCountry ~= npcCountry then
					local atWar = DM.areCountriesAtWar(npcCountry, occupantCountry)
					if atWar then
						local hrp = occupant:FindFirstChild("HumanoidRootPart")
						if hrp then
							table.insert(enemyPositions, hrp.Position)
						end
					end
				end
			end
		end
	end

	-- Compute safety score for each candidate
	for _, cand in ipairs(candidates) do
		local candCenter = TAM.getSafeCenter(cand.part)
		if not candCenter then
			candCenter = cand.part.Position
		end

		if #enemyPositions == 0 then
			cand.score = math.huge
		else
			local minDist = math.huge
			for _, enemyPos in ipairs(enemyPositions) do
				local dist = (candCenter - enemyPos).Magnitude
				if dist < minDist then
					minDist = dist
				end
			end
			cand.score = minDist
		end
	end

	-- Sort: safest first (highest score). Deterministic tie-break by tileId ascending.
	table.sort(candidates, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.tileId < b.tileId
	end)

	-- Exhaustive attempt: try each candidate best-first (reuses moveSystem from Precondition 2b)
	for _, cand in ipairs(candidates) do
		reserveRetreatTile(npcModel, cand.tileId)

		local success, _err = moveSystem.startHealthRetreat(npcModel, cand.part)
		if success then
			-- Movement started: NOW apply combat disengagement + set attribute
			Combat.disengageForRetreat(npcModel)
			npcModel:SetAttribute("RetreatState", "Retreating")

			if DEBUG then
				print("[Combat] " .. npcModel.Name .. " retreating to tile " .. cand.tileId
					.. " (score=" .. string.format("%.1f", cand.score == math.huge and -1 or cand.score) .. ")")
			end
			return true
		else
			-- Failed: release reservation and try next
			releaseRetreatReservation(npcModel)
		end
	end

	-- All candidates failed — NPC is trapped, no escape
	if DEBUG then
		print("[Combat] " .. npcModel.Name .. " retreat failed — all candidates exhausted, killing NPC")
	end
	humanoid.Health = 0
	return false
end
```

- [ ] **Step 2: Commit**

```bash
git add src/shared/NPCCombatSystem.lua
git commit -m "feat(retreat): implement tryTriggerRetreat with tile selection algorithm"
```

---

## Task 6: Combat Loop Integration — Skip Guard + Retreat Trigger

**Files:**
- Modify: `src/shared/NPCCombatSystem.lua`

- [ ] **Step 1: Add RetreatState skip guard and retreat trigger to combat loop**

In the `startCombatLoop` function, inside the `while` loop body (line 312, right after the `while` condition), insert at the TOP of the loop body — before `local now = os.clock()`:

```lua
			-- Skip all combat logic while actively retreating (invulnerable transit)
			if npcModel:GetAttribute("RetreatState") == "Retreating" then
				task.wait(LOOP_WAIT)
				continue
			end

			-- Check for retreat trigger (before processing targets)
			if Combat.tryTriggerRetreat(npcModel) then
				task.wait(LOOP_WAIT)
				continue
			end
```

Note: the old plan skipped for both `"Retreating"` and `"Recovering"`. The skip is now `"Retreating"` only. Recovering / SkullActive NPCs let the loop run so auto-retaliation works — the `getAllTargets` callbacks already filter out manual targets when `SkullActive` is set (see Task 7 Step 3 addendum below).

- [ ] **Step 2: Verify the loop body order is correct**

After this insertion, the combat loop body should read:
1. Retreating skip guard → `continue`
2. `tryTriggerRetreat` call → `continue` if triggered
3. `local now = os.clock()` (existing)
4. `getAllTargets()` (existing) — callbacks filter manual targets when SkullActive
5. `updateCombatHealthState(...)` (existing)
6. ... rest of existing loop body

- [ ] **Step 3: Commit**

```bash
git add src/shared/NPCCombatSystem.lua
git commit -m "feat(retreat): wire tryTriggerRetreat into combat loop with skip guard"
```

---

## Task 7: Attack Guards + Invulnerability Protections

**Files:**
- Modify: `src/shared/NPCCombatSystem.lua`
- Modify: `src/server/NPCTargetingHandler.server.lua`

- [ ] **Step 1: Guard Combat.addManualTarget — reject if attacker is Retreating, Recovering, or SkullActive**

In `Combat.addManualTarget` (around line 461), insert at the top of the function, after the nil check:

```lua
	-- ANY code path that initiates offensive combat MUST check RetreatState and SkullActive.
	-- Retreating/Recovering NPCs and NPCs with skull (SkullActive) cannot initiate attacks.
	-- SkullActive persists after movement cancels Recovering, blocking attacks until healed.
	local attackerRetreatState = attackerModel:GetAttribute("RetreatState")
	if attackerRetreatState == "Retreating" or attackerRetreatState == "Recovering"
		or attackerModel:GetAttribute("SkullActive") then
		if DEBUG then
			print("[Combat] " .. attackerModel.Name .. " cannot target: RetreatState="
				.. tostring(attackerRetreatState) .. ", SkullActive=" .. tostring(attackerModel:GetAttribute("SkullActive")))
		end
		return false
	end
```

- [ ] **Step 2: Guard Combat.noteHit — block for Retreating only (allow Recovering/SkullActive for defense)**

In `Combat.noteHit` (around line 824), insert after the `if targetNpc:GetAttribute("Dead") then return end` check:

```lua
	-- Retreating NPCs are invulnerable — skip all hit processing
	if targetNpc:GetAttribute("RetreatState") == "Retreating" then
		return
	end
```

Note: this intentionally does NOT block for `"Recovering"` or `SkullActive`. Recovering/SkullActive NPCs need `noteHit` to register threats so their combat loop can auto-retaliate (defend). The attack *initiation* block is handled by `addManualTarget` and the `getAllTargets` manual-target filter.

- [ ] **Step 2b: Broaden Attacker threat tracking in Combat.noteHit for ALL attackers (not just AutoRetaliate)**

In `Combat.noteHit` (around line 823), the existing code has Attacker threat tracking gated behind the `AutoRetaliate` check (line 856). Player-owned attackers never get threats registered, so they can never retreat. Fix: move the Attacker threat tracking ABOVE the `AutoRetaliate` guard.

Find the block starting at line 855:

```lua
	-- Auto-retaliation threat tracking only for AutoRetaliate NPCs (country-owned)
	if targetNpc:GetAttribute("AutoRetaliate") ~= true then return end

	if targetRole == "Defender" then
		Combat.noteAttackerTargeting(attackerNpc, targetNpc)
	elseif targetRole == "Attacker" then
		Combat.noteTargetingAttacker(attackerNpc, targetNpc)
	end
```

Replace with:

```lua
	-- Attacker threat tracking for ALL NPCs (needed for retreat decisions).
	-- Runs regardless of AutoRetaliate so player-owned Attackers can retreat.
	if targetRole == "Attacker" then
		Combat.noteTargetingAttacker(attackerNpc, targetNpc)
	end

	-- Defender retreat-threat tracking for ALL Defenders (separate from auto-retaliation).
	-- Uses defenderRetreatThreats table so player-owned Defenders can retreat
	-- WITHOUT accidentally populating defenderAttackers (which drives auto-retaliation).
	if targetRole == "Defender" then
		Combat.noteDefenderRetreatThreat(attackerNpc, targetNpc)
	end

	-- Auto-retaliation only for AutoRetaliate NPCs (country-owned)
	if targetNpc:GetAttribute("AutoRetaliate") ~= true then return end

	-- Auto-retaliation target tracking (only reaches here for AutoRetaliate NPCs)
	if targetRole == "Defender" then
		Combat.noteAttackerTargeting(attackerNpc, targetNpc)
	end
```

**Important:** This separates retreat-threat tracking from auto-retaliation tracking. `defenderRetreatThreats` is populated for ALL Defenders (enabling retreat), while `defenderAttackers` is only populated for `AutoRetaliate` NPCs (enabling auto-retaliation). Without this separation, player-owned Defenders would accidentally auto-retaliate via the combat loop reading `defenderAttackers`.

The helper functions (`noteDefenderRetreatThreat`, `getDefenderRetreatThreatCount`, `removeNPCFromDefenderRetreatThreats`) and the `defenderRetreatThreats` table were already added in Task 1 Steps 4 and 5b. The `tryTriggerRetreat` Defender precondition (Task 5) already uses `getDefenderRetreatThreatCount`. Reciprocal cleanup is already wired into `disengageForRetreat` and `cleanupRetreatState`.

- [ ] **Step 3: Guard Attacker getAllTargets callback — filter retreating targets + skip manual targets when SkullActive**

In `Combat.registerNPC`, inside the Attacker `getAllTargets` callback (around line 602), there are two sections: **manual targets** and **threats**. Both need guards.

**3a. Manual targets section:** At the very top of the manual targets loop (around line 606, before `for i = #targets, 1, -1 do`), add a SkullActive check that skips ALL manual targets. SkullActive NPCs can only defend (auto-retaliate via threats), not attack (via manual targets):

```lua
			-- SkullActive NPCs cannot use manual targets (no offensive attacks)
			if not npcModel:GetAttribute("SkullActive") then
```

Then wrap the entire existing `for i = #targets, 1, -1 do` loop inside this `if` block, and close it with `end` after the loop ends.

**3b. Inside the manual targets loop** (the loop that's now inside the SkullActive guard), change line 621 from:

```lua
					if targetHumanoid and targetHumanoid.Health > 0 and canFight and isAdjacent then
						table.insert(allValidTargets, targetHumanoid)
```

to:

```lua
					if targetHumanoid and targetHumanoid.Health > 0 and canFight and isAdjacent then
						if getNPCMovementSystem().isRetreating(target) then
							table.remove(targets, i)
						else
							table.insert(allValidTargets, targetHumanoid)
						end
```

The result: SkullActive NPCs skip manual targets entirely. Non-SkullActive NPCs process manual targets but filter out retreating (invulnerable) targets.

- [ ] **Step 4: Guard Attacker getAllTargets callback — filter retreating threats**

In the same Attacker callback, inside the threats loop (around line 653), apply the same pattern. Change:

```lua
						if threatHumanoid and threatHumanoid.Health > 0 and canFight and isAdjacent then
```

Replace with the full updated block (includes the retreating check and the `alreadyTargeted` dedup logic together):

```lua
						if threatHumanoid and threatHumanoid.Health > 0 and canFight and isAdjacent then
							if getNPCMovementSystem().isRetreating(threat) then
								table.remove(threats, i)
							else
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
							end
```

- [ ] **Step 5: Guard Defender getAllTargets callback — filter retreating attackers**

In the Defender `getAllTargets` callback (around line 692), change:

```lua
					if attHumanoid and attHumanoid.Health > 0 and canFight and isAdjacent then
						table.insert(allValidTargets, attHumanoid)
```

to:

```lua
					if attHumanoid and attHumanoid.Health > 0 and canFight and isAdjacent then
						if getNPCMovementSystem().isRetreating(att) then
							table.remove(attackers, i)
						else
							table.insert(allValidTargets, attHumanoid)
						end
```

- [ ] **Step 6: Add damage-time guard in fireMultiLaser**

In the `fireMultiLaser` function (around line 240), inside the `for _, targetHumanoid in ipairs(targetHumanoids) do` loop, the existing code reads:

```lua
	for _, targetHumanoid in ipairs(targetHumanoids) do
		if targetHumanoid and targetHumanoid.Health > 0 then
			local targetRoot = getRootPart(targetHumanoid.Parent)
			if targetRoot then
				createLaserBeam(npcRoot.Position, targetRoot.Position, beamColor)
				targetHumanoid:TakeDamage(damagePerTarget)
```

Insert the retreat guard **inside** the `if targetRoot then` block, before `createLaserBeam`. The result:

```lua
	for _, targetHumanoid in ipairs(targetHumanoids) do
		if targetHumanoid and targetHumanoid.Health > 0 then
			local targetRoot = getRootPart(targetHumanoid.Parent)
			if targetRoot then
				-- Damage-time guard: target may have begun retreating after target list was built
				local targetNpcModel = targetHumanoid.Parent
				if targetNpcModel and targetNpcModel:GetAttribute("RetreatState") == "Retreating" then
					continue
				end
				createLaserBeam(npcRoot.Position, targetRoot.Position, beamColor)
				targetHumanoid:TakeDamage(damagePerTarget)
```

The `continue` skips the rest of the `for` loop iteration, so the retreating target gets no beam and no damage.

- [ ] **Step 7: Guard NPCTargetingHandler — block SkullActive/Retreating/Recovering attacker from initiating attacks**

In `src/server/NPCTargetingHandler.server.lua`, in the `handleSecondClick` function (around line 175), after the adjacency check block and after the existing retreating target check (line 183–186), add a guard for the ATTACKER's state:

```lua
	-- Block attack initiation if attacker is Retreating, Recovering, or has skull (SkullActive)
	local attackerRetreatState = attackerModel:GetAttribute("RetreatState")
	if attackerRetreatState == "Retreating" or attackerRetreatState == "Recovering"
		or attackerModel:GetAttribute("SkullActive") then
		if DEBUG then print("Cannot attack: " .. attackerModel.Name .. " has skull or is " .. tostring(attackerRetreatState) .. " — can defend but not initiate") end
		return
	end
```

Insert this block after the existing target retreat check (after line 186, before the `-- ADD target to the list` comment).

- [ ] **Step 8: Commit**

```bash
git add src/shared/NPCCombatSystem.lua src/server/NPCTargetingHandler.server.lua
git commit -m "feat(retreat): add RetreatState guards at all attack entry points + invulnerability"
```

---

## Task 8: Cleanup Integration

**Files:**
- Modify: `src/shared/NPCCombatSystem.lua`
- Modify: `src/shared/NPCMovementSystem.lua`
- Modify: `src/server/NPCSpawner.lua`

- [ ] **Step 1: Add cleanupRetreatState call to Combat.unregisterNPC**

In `Combat.unregisterNPC` (around line 720), insert `Combat.cleanupRetreatState(npcModel)` as defense-in-depth. Add it after the maid cleanup (Step 2, after `runtime.maid:DoCleaning()`) and before clearing per-NPC tables (Step 4). Insert after line 740 (after `npcRuntime[npcModel] = nil`):

```lua
	-- Defense-in-depth: clear retreat state
	Combat.cleanupRetreatState(npcModel)
```

- [ ] **Step 2: Add cleanupRetreatState call to Combat.transferOwnership**

In `Combat.transferOwnership` (around line 404, anchor: `function Combat.transferOwnership`), insert cleanup after clearing manual targets and threat lists (after the removal loops, before the `moveSystem.OnOwnerChanged` call around line 445):

```lua
	-- Cancel active health retreat movement before clearing gameplay state.
	-- OnOwnerChanged() returns early for "Retreating" movement state, so without
	-- this explicit cancellation the NPC continues walking with cleared gameplay state.
	-- NOTE: reuse the existing `moveSystem` local if transferOwnership already declares one
	-- (it typically does for the moveSystem.OnOwnerChanged call below). If not, add this:
	local moveSystem = getNPCMovementSystem()
	if moveSystem.cancelHealthRetreat then
		moveSystem.cancelHealthRetreat(npcModel)
	end

	-- Clear retreat state on ownership transfer
	Combat.cleanupRetreatState(npcModel)
```

**Note:** The existing `transferOwnership` function likely already declares `local moveSystem = getNPCMovementSystem()` for the `moveSystem.OnOwnerChanged(npcModel)` call further down. If so, remove the duplicate declaration above and reuse the existing one — just insert the `cancelHealthRetreat` call using the already-declared variable.

- [ ] **Step 3: Route NPCSpawner cleanup through cleanupRetreatState**

In `src/server/NPCSpawner.lua`, in the `cleanup` function (around line 107), insert before the `Combat.unregisterNPC(npcClone)` call (before line 145):

```lua
		-- Clean up retreat state before unregistering from combat
		Combat.cleanupRetreatState(npcClone)
```

- [ ] **Step 4: Add movement-cancels-recovery to NPCMovementSystem.startMovement**

In `src/shared/NPCMovementSystem.lua`, in `NPCMovementSystem.startMovement` (around line 1699), after the retreating check (after `if NPCMovementSystem.isRetreating(npcModel) then return false, "NPC is retreating" end` at line 1709–1711), add:

```lua
	-- Movement cancels Recovering state (NPC can fight again) but skull persists until healed
	if npcModel:GetAttribute("RetreatState") == "Recovering" then
		npcModel:SetAttribute("RetreatState", "None")
	end
```

- [ ] **Step 5: Clear retreat state data in NPCMovementSystem.OnOwnerChanged**

In `NPCMovementSystem.OnOwnerChanged` (around line 2050, anchor: `function NPCMovementSystem.OnOwnerChanged`), add a health-retreat cancellation block **before** the generic early return for `"Moving"` or `"Retreating"` movement state (around line 2058). Simply clearing the flag is insufficient — the active movement would continue with cleared gameplay state, causing desync on arrival. Instead, call the full cancellation path and return early:

```lua
	-- Health retreats must be fully cancelled before the generic Retreating early return.
	-- Otherwise the NPC continues walking with gameplay retreat state already cleared by
	-- Combat.transferOwnership(), and arrival code finds RetreatState ~= "Retreating".
	if movementStates[npcModel] and movementStates[npcModel].isHealthRetreat then
		NPCMovementSystem.cancelHealthRetreat(npcModel)
		return
	end
```

Insert this block immediately before the `if movementStates[npc].state == "Moving" or movementStates[npc].state == "Retreating" then return end` guard. The `return` ensures this path doesn't fall through to the generic handler — the health retreat is fully cancelled (movement stopped, state reset, NPC snapped back).

- [ ] **Step 6: Commit**

```bash
git add src/shared/NPCCombatSystem.lua src/shared/NPCMovementSystem.lua src/server/NPCSpawner.lua
git commit -m "feat(retreat): integrate cleanup into unregister, transfer, spawner, and movement"
```

---

## Verification Checklist

After all tasks are complete, tell the user to playtest each scenario in Roblox Studio but you have to explain it simply so the user understands:

- [ ] **Basic retreat:** Place a Defender on a tile with adjacent friendly tiles. Attack it with enemy Attackers until health < 30%. Verify: NPC disengages, walks to an adjacent friendly tile (invulnerable during walk), arrives, shows skull, regenerates, skull disappears when health > 55%.
- [ ] **Attacker retreat (defending):** Place a player-owned Attacker. Have an enemy attack it. Verify: Attacker with threats retreats when health drops below 30%.
- [ ] **Attacker halt (attacking):** Direct a player-owned Attacker to attack an enemy. Let it take damage until low health, but ensure no enemy is counter-attacking it (getThreatCount == 0). Verify: Attacker clears its manual targets and stops fighting, but does NOT retreat. It stays on its tile. *(Note: this "halt" behavior is emergent — `tryTriggerRetreat` returns `false` because `getThreatCount == 0`, the manual target clear in the Attacker-no-threats branch fires, the combat loop finds no targets, and the NPC idles. There is no explicit "halt" code path.)*
- [ ] **Attacker mutual combat:** Direct a player-owned Attacker to attack an enemy Defender. The Defender fights back (threats registered). Attacker reaches low health. Verify: Attacker retreats (because it has threats > 0).
- [ ] **Invulnerability:** While an NPC is walking to its retreat tile, attempt to attack it. Verify: attacks are filtered out, no damage is applied.
- [ ] **Recovering defense:** After an NPC arrives and shows skull, attack it with another NPC. Use a player-owned Attacker or a country-owned Defender (`AutoRetaliate == true`) as the recovering NPC. Verify: the Recovering NPC takes damage AND auto-retaliates defensively, but cannot be manually directed to attack new targets. (Player-owned Defenders do not auto-retaliate — see auto-retaliation clarification above.)
- [ ] **Move during recovery:** Select a Recovering NPC and issue a move order. Verify: NPC moves, skull persists, NPC still CANNOT initiate attacks (SkullActive blocks manual targeting). NPC CAN still auto-retaliate if attacked. Skull disappears when health crosses threshold, then NPC is fully operational.
- [ ] **No retreat tiles (trapped = death):** Surround an NPC so all adjacent friendly tiles are occupied or non-friendly. Verify: retreat fails and NPC is killed instantly (health set to 0). Normal death cleanup runs.
- [ ] **Simultaneous retreat:** Have two NPCs on adjacent tiles both take damage. Verify: reservation system prevents them from retreating to the same tile.
- [ ] **Death during recovery:** Kill a Recovering NPC. Verify: normal death cleanup runs, skull hidden, reservation released, listener disconnected.
- [ ] **Ownership transfer:** Transfer a Recovering NPC's country. Verify: retreat state cleared, skull hidden, NPC becomes fully operational under new owner.
- [ ] **Skull attack block:** While an NPC has the skull (SkullActive), try to manually target an enemy via second-click. Verify: targeting is rejected. Then have an enemy attack the skull NPC. Verify: the skull NPC auto-retaliates (fires back defensively).
- [ ] **Player-owned Defender retreat:** Place a player-owned Defender. Have an enemy attack it until health < 30%. Verify: Defender retreats when attacked. Also verify it does NOT auto-retaliate (no `AutoRetaliate` attribute) — it should only retreat, not fight back. Country-owned Defenders (AutoRetaliate = true) should both retreat AND auto-retaliate.
- [ ] **Ownership transfer during active retreat:** Trigger an NPC health retreat, then transfer ownership (e.g., player leaves) while the NPC is still walking mid-transit. Verify: health retreat movement is cancelled, NPC snaps back to origin, retreat state is cleared, skull does NOT appear, no arrival callback fires later, and tile occupancy remains consistent (NPC stays on its original tile).
- [ ] **NPC destruction:** Destroy a Retreating NPC mid-transit. Verify: no errors, reservation released, callback does not fire.

---

## Constants Reference

```lua
RETREAT_THRESHOLD = 0.30     -- health ratio below which retreat triggers
RECOVERY_THRESHOLD = 0.55    -- health ratio above which recovery clears
```

These are placeholders — tune based on playtesting. Note: there is no retry cooldown. If retreat fails (no valid tiles), the NPC dies instantly.
