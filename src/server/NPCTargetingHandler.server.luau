-- NPCTargetingHandler (MULTI-TARGET + MOVEMENT VERSION)
-- Added tile click detection for NPC movement system
-- Click NPC head = select for targeting
-- With NPC selected: click enemy NPC head = attack, click tile = move

local Combat = require(game.ServerScriptService:WaitForChild("NPCCombatSystem", 10))
local TileAdjacencyManager = require(game.ServerScriptService:WaitForChild("TileAdjacencyManager", 10))
local TileManager = require(game.ServerScriptService:WaitForChild("TileManager", 10))
local DiplomacyManager = require(game.ServerScriptService:WaitForChild("DiplomacyManager", 10))
local NPCMovementSystem = require(game.ServerScriptService:WaitForChild("NPCMovementSystem", 10))
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local NPC_TAG = "RegisteredNPC"

local DEBUG = false

local SelectionVisualEvent = ReplicatedStorage:WaitForChild("SelectionVisualEvent", 10)
local NPCMoveToTileEvent = ReplicatedStorage:WaitForChild("NPCMoveToTileEvent", 10)

local EUROPE_MAP = Workspace:WaitForChild("EuropeMap", 10)

local selectedNPC = {} -- player -> npcModel

-- Store both the flag AND the connection for proper cleanup
-- connectedNPCs[npcModel] = { connected = true, clickConnection = RBXScriptConnection }
local connectedNPCs = {}

local function getNPCModel(part)
	local model = part.Parent
	while model and not model:IsA("Model") do
		model = model.Parent
	end
	if model and model:FindFirstChildOfClass("Humanoid") and model:FindFirstChild("NPCOwner") then
		return model
	end
	return nil
end

-- Helper to check if a part is a tile (inside EuropeMap)
local function isTilePart(part)
	if not part or not part:IsA("BasePart") then return false end

	-- Walk up to check if this part is inside EuropeMap
	local current = part.Parent
	while current and current ~= Workspace do
		if current == EUROPE_MAP then
			return true
		end
		if current.Parent == EUROPE_MAP then
			return true
		end
		current = current.Parent
	end
	return false
end

-- Helper to get country model from a tile part
local function getTileCountryModel(part)
	local current = part.Parent
	while current and current ~= EUROPE_MAP and current ~= Workspace do
		if current.Parent == EUROPE_MAP then
			return current
		end
		current = current.Parent
	end
	return nil
end

-- Helper: Find a living NPC occupying a tile.
-- Uses TileId-authoritative lookup directly (tilePart is already available from click handler).
local function findNPCOnTile(tilePart)
	local tileId = TileAdjacencyManager.getTileId(tilePart)
	if not tileId then return nil end
	local npc = TileManager.getTileOccupantById(tileId)
	if npc and npc.Parent and npc:FindFirstChildOfClass("Humanoid") then
		local humanoid = npc:FindFirstChildOfClass("Humanoid")
		if humanoid.Health > 0 then
			return npc
		end
	end
	return nil
end

-- Helper to clear selection for a player
local function clearSelection(player)
	local currentSelection = selectedNPC[player]
	if currentSelection then
		SelectionVisualEvent:FireClient(player, currentSelection, false)
		selectedNPC[player] = nil
		if DEBUG then print(player.Name .. " deselected their unit") end
	end
end

local function handleFirstClick(player, npcModel)
	local owner = Combat.getOwner(npcModel)

	if not owner then
		if DEBUG then print(player.Name .. " cannot select NPC: No owner registered") end
		return
	end

	-- Check if NPC is retreating (can't be selected)
	if NPCMovementSystem.isRetreating(npcModel) then
		if DEBUG then print(player.Name .. " cannot select NPC: Currently retreating") end
		return
	end

	if owner == player then
		-- Clear old selection highlight (but keep the NPC's targets!)
		local oldNPC = selectedNPC[player]
		if oldNPC then
			SelectionVisualEvent:FireClient(player, oldNPC, false)
		end

		selectedNPC[player] = npcModel

		local targetCount = Combat.getManualTargetCount(npcModel)
		local movementState = NPCMovementSystem.getMovementState(npcModel)
		if DEBUG then print(player.Name .. " selected: " .. npcModel.Name .. " (targeting " .. targetCount .. " enemies, state: " .. movementState .. ")") end

		SelectionVisualEvent:FireClient(player, npcModel, true)
	else
		local ownerName = "Unknown"
		if typeof(owner) == "Instance" and owner:IsA("Player") then
			ownerName = owner.Name
		elseif typeof(owner) == "Instance" then
			ownerName = owner.Name or "ServerOwned"
		end
		if DEBUG then print(player.Name .. " cannot select NPC owned by: " .. ownerName) end
	end
end

local function handleSecondClick(player, targetModel)
	local attackerModel = selectedNPC[player]
	if not attackerModel then
		if DEBUG then print(player.Name .. " needs to select an Attacker first.") end
		return
	end

	local attackerOwner = Combat.getOwner(attackerModel)

	-- Only require attacker to have an owner
	if not attackerOwner then
		if DEBUG then print("Cannot process attack: Your attacker has no owner") end
		return
	end

	local attackerRole = Combat.getRole(attackerModel)
	local targetRole = Combat.getRole(targetModel)

	-- Use country-based attack validation so country-owned (nil-owner) NPCs are handled correctly
	if not DiplomacyManager.canNPCAttack(attackerModel, targetModel) then
		-- Determine reason for better feedback using country attributes
		local attackerCountry = attackerModel:GetAttribute("Country")
		local targetCountry = targetModel:GetAttribute("Country")
		if attackerCountry == targetCountry then
			if DEBUG then print("Cannot attack: " .. targetModel.Name .. " is owned by you") end
		elseif DiplomacyManager.areCountriesAllied(attackerCountry, targetCountry) then
			if DEBUG then print("Cannot attack: " .. targetModel.Name .. " belongs to an allied country") end
		else
			if DEBUG then print("Cannot attack: You are not at war with " .. targetModel.Name .. "'s country") end
		end
		return
	end

	-- Rule 2: Only Attackers can be manually directed
	if attackerRole ~= "Attacker" then
		if DEBUG then print(attackerModel.Name .. " is a Defender and cannot be manually directed to attack.") end
		clearSelection(player)
		return
	end

	if NPCMovementSystem.isMoving(attackerModel) then
		if DEBUG then print("Cannot attack: " .. attackerModel.Name .. " is currently moving") end
		return
	end

	-- Rule 3: Tile adjacency check
	if not TileAdjacencyManager.canNPCsInteract(attackerModel, targetModel) then
		if DEBUG then print("Cannot attack: " .. targetModel.Name .. " is not on an adjacent tile") end
		return
	end

	-- Check if target is retreating (invulnerable)
	if NPCMovementSystem.isRetreating(targetModel) then
		if DEBUG then print("Cannot attack: " .. targetModel.Name .. " is retreating (invulnerable)") end
		return
	end

	if NPCMovementSystem.isMoving(targetModel) then
		local restored, restoreResult = NPCMovementSystem.restoreToMovementOrigin(targetModel)
		if not restored then
			if DEBUG then print("Cannot attack: failed to restore moving target " .. targetModel.Name .. " (" .. tostring(restoreResult) .. ")") end
			return
		end
	end

	-- ADD target to the list (not replace!)
	local added = Combat.addManualTarget(attackerModel, targetModel)

	if added then
		-- Notify the target that they're being attacked (for auto-retaliation)
		if targetRole == "Defender" then
			Combat.noteAttackerTargeting(attackerModel, targetModel)
		elseif targetRole == "Attacker" then
			Combat.noteTargetingAttacker(attackerModel, targetModel)
		end

		local targetCount = Combat.getManualTargetCount(attackerModel)
		if DEBUG then print(attackerModel.Name .. " now targeting " .. targetCount .. " enemy(s) (added " .. targetModel.Name .. ")") end
	else
		if DEBUG then print(attackerModel.Name .. " is already targeting " .. targetModel.Name) end
	end

	-- Always clear selection after assigning a target
	clearSelection(player)
end

-- Handle tile click for movement
local function handleTileClick(player, tilePart)
	local npcModel = selectedNPC[player]
	if not npcModel then
		if DEBUG then print(player.Name .. " needs to select an NPC first.") end
		return
	end

	-- Check if target tile is directly adjacent before allowing movement
	-- MUST verify adjacency - block movement if we can't determine current tile
	local currentTileId = npcModel:GetAttribute("CurrentTileId")
	local currentTilePart = currentTileId and TileAdjacencyManager.getTileFromId(currentTileId) or nil
	if not currentTilePart then
		local currentTileKey = npcModel:GetAttribute("TileKey")
		if not currentTileKey then
			if DEBUG then print("Movement failed: NPC has no current tile") end
			clearSelection(player)
			return
		end

		currentTilePart = TileAdjacencyManager.getTileFromKey(currentTileKey)
		if not currentTilePart then
			currentTilePart = TileAdjacencyManager.getTileFromKeyWithFallback(currentTileKey)
		end
	end
	if not currentTilePart then
		if DEBUG then print("Movement failed: Could not resolve NPC's current tile") end
		clearSelection(player)
		return
	end

	-- Validate NPC is actually near its resolved tile (prevents TileKey mismatch in small countries)
	-- If the NPC's physical position is far from the resolved tile, re-resolve from actual position
	local npcRoot = npcModel:FindFirstChild("HumanoidRootPart") or npcModel.PrimaryPart
	if npcRoot and currentTilePart then
		local npcPosXZ = npcRoot.Position * Vector3.new(1, 0, 1)
		local tilePosXZ = currentTilePart.Position * Vector3.new(1, 0, 1)
		local tileDistance = (npcPosXZ - tilePosXZ).Magnitude

		-- If NPC is far from its attributed tile, re-resolve from physical position
		if tileDistance > currentTilePart.Size.Magnitude / 2 + 5 then
			local correctedTile = TileAdjacencyManager.getTileUnderPosition(npcRoot.Position)
			if correctedTile then
				if DEBUG then print("[Movement] TileKey mismatch corrected: " .. currentTilePart.Name .. " -> " .. correctedTile.Name .. " (NPC was " .. math.floor(tileDistance) .. " studs from attributed tile)") end
				currentTilePart = correctedTile
				-- Update the NPC's TileKey to prevent future mismatches
				local correctedKey = TileManager.getTileKeyFromPart(correctedTile)
				if correctedKey then
					npcModel:SetAttribute("TileKey", correctedKey)
				end
				-- Fix C: Update CurrentTileId to match the corrected tile
				local correctedTileId = TileAdjacencyManager.getTileId(correctedTile)
				if correctedTileId then
					npcModel:SetAttribute("CurrentTileId", correctedTileId)
				end
			end
		end
	end

	-- Add distance check as a safeguard against invalid tile resolution
	local distance = (currentTilePart.Position - tilePart.Position).Magnitude
	if distance > 100 then -- Tiles should be within reasonable distance
		if DEBUG then print("[Movement] BLOCKED: Target tile too far (" .. math.floor(distance) .. " studs)") end
		clearSelection(player)
		return
	end

	-- Debug logging to help diagnose adjacency issues
	local isAdjacent = TileAdjacencyManager.areTilesAdjacent(currentTilePart, tilePart)
	if DEBUG then
		print("[Movement] " .. player.Name .. " moving from " .. currentTilePart.Name .. " to " .. tilePart.Name)
		print("[Movement] Distance: " .. math.floor(distance) .. " studs | Adjacent: " .. tostring(isAdjacent))
	end

	-- Check adjacency - must be directly adjacent (one tile away)
	if not isAdjacent then
		-- Full diagnostic when adjacency fails
		TileAdjacencyManager.diagnoseAdjacency(currentTilePart, tilePart)

		local repaired = TileAdjacencyManager.tryRepairAdjacencyPair(currentTilePart, tilePart)
		if repaired then
			isAdjacent = TileAdjacencyManager.areTilesAdjacent(currentTilePart, tilePart)
			if isAdjacent then
				if DEBUG then print(string.format("[Movement] Repaired adjacency at runtime: %s <-> %s", currentTilePart.Name, tilePart.Name)) end
			end
		else
			if DEBUG then print(string.format("[Movement] Runtime adjacency repair did not connect: %s <-> %s", currentTilePart.Name, tilePart.Name)) end
		end

		if not isAdjacent then
			if DEBUG then print("Movement failed: Target tile (" .. tilePart.Name .. ") is not adjacent to current tile (" .. currentTilePart.Name .. ")") end
			clearSelection(player)
			return
		end
	end

	-- Secondary validation: confirm a walkable crossing proof exists for this pair.
	-- areTilesAdjacent() is a lookup-only check; the proof confirms a real walkable border.
	local proof = TileAdjacencyManager.getAdjacencyProof(currentTilePart, tilePart)
	if not proof then
		if DEBUG then print("[Movement] BLOCKED: No walkable crossing proof for " .. currentTilePart.Name .. " -> " .. tilePart.Name .. " (adjacency table false positive?)") end
		clearSelection(player)
		return
	end

	-- Block movement while the NPC is engaged in combat
	if Combat.isInCombat(npcModel) then
		if DEBUG then print("[Movement] " .. npcModel.Name .. " cannot move: currently engaged in combat") end
		clearSelection(player)
		return
	end

	-- Check if NPC is moving (cancel current movement for new order)
	if NPCMovementSystem.isMoving(npcModel) then
		NPCMovementSystem.cancelMovement(npcModel)
	end

	-- Get tile key
	local targetTileKey = TileManager.getTileKeyFromPart(tilePart)
	if not targetTileKey then
		if DEBUG then print("Could not determine tile key for clicked part") end
		clearSelection(player)
		return
	end

	-- Attempt to move
	local success, errorMsg = NPCMovementSystem.startMovement(npcModel, targetTileKey, tilePart)

	if success then
		if DEBUG then print(npcModel.Name .. " moving to tile " .. targetTileKey) end
	else
		if DEBUG then print("Movement failed: " .. (errorMsg or "Unknown error")) end
	end

	-- Clear selection after issuing movement order
	clearSelection(player)
end

-- Disconnect and clean up NPC connections properly
local function disconnectNPC(npcModel)
	local data = connectedNPCs[npcModel]
	if data then
		if data.clickConnection then
			data.clickConnection:Disconnect()
		end
		connectedNPCs[npcModel] = nil
	end
end

local function connectNPC(npcModel)
	if connectedNPCs[npcModel] then return end

	local head = npcModel:FindFirstChild("Head")
	if not head then return end

	local clickDetector = head:FindFirstChild("ClickDetector")
	if not clickDetector then return end

	-- Store the connection so we can disconnect it later
	local clickConnection = clickDetector.MouseClick:Connect(function(player)
		local npc = getNPCModel(head)
		if not npc then return end

		-- Ignore dead/dying NPCs (cleanup sets Dead=true and destroys ClickDetector,
		-- but guard here as a belt-and-suspenders safety check)
		local hum = npc:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 or npc:GetAttribute("Dead") then return end

		-- Check if clicking your currently selected NPC (deselect)
		if selectedNPC[player] == npc then
			clearSelection(player)
			return
		end

		if selectedNPC[player] then
			handleSecondClick(player, npc)
		else
			handleFirstClick(player, npc)
		end
	end)

	-- Store both the flag and the connection
	connectedNPCs[npcModel] = {
		connected = true,
		clickConnection = clickConnection
	}

	-- Also disconnect when NPC is destroyed
	npcModel.Destroying:Once(function()
		disconnectNPC(npcModel)
	end)
end

-- Initialize existing registered NPCs
for _, npcModel in ipairs(CollectionService:GetTagged(NPC_TAG)) do
	connectNPC(npcModel)
end

-- Connect new NPCs when they receive the RegisteredNPC tag
CollectionService:GetInstanceAddedSignal(NPC_TAG):Connect(function(npcModel)
	connectNPC(npcModel)
end)

-- Clean up player state when they leave
Players.PlayerRemoving:Connect(function(player)
	if selectedNPC[player] then
		selectedNPC[player] = nil
	end
end)

-- Clean up NPC tracking when an NPC is unregistered or destroyed
CollectionService:GetInstanceRemovedSignal(NPC_TAG):Connect(function(npcModel)
	disconnectNPC(npcModel)

	-- Also clear from any player's selection
	for player, npc in pairs(selectedNPC) do
		if npc == npcModel then
			selectedNPC[player] = nil
		end
	end
end)

-- Listen for tile click events from client
-- Supports: tile-based NPC selection, movement, and combat assignment
NPCMoveToTileEvent.OnServerEvent:Connect(function(player, tilePart)
	-- Validate that it's actually a tile
	if not isTilePart(tilePart) then return end

	-- Security: Verify tilePart is a real tile inside a country
	local countryModel = getTileCountryModel(tilePart)
	if not countryModel then return end

	-- Find NPC on the clicked tile (if any)
	local npcOnTile = findNPCOnTile(tilePart)

	-- CASE 1: No NPC currently selected — try to select NPC on clicked tile
	if not selectedNPC[player] then
		if npcOnTile then
			local npcOwner = Combat.getOwner(npcOnTile)
			if npcOwner == player then
				handleFirstClick(player, npcOnTile)
			end
		end
		return
	end

	-- CASE 2: Player has a selected NPC
	local myNPC = selectedNPC[player]

	-- Security: Validate ownership of selected NPC
	if Combat.getOwner(myNPC) ~= player then
		selectedNPC[player] = nil
		return
	end

	if npcOnTile then
		local tileNPCOwner = Combat.getOwner(npcOnTile)

		if tileNPCOwner == player then
			-- Own NPC on target tile: deselect if same, switch selection if different
			if npcOnTile == myNPC then
				clearSelection(player)
			else
				handleFirstClick(player, npcOnTile)
			end
			return
		end

		-- Enemy NPC on target tile: attempt combat assignment
		handleSecondClick(player, npcOnTile)
		return
	end

	-- Empty tile: attempt movement
	handleTileClick(player, tilePart)
end)
