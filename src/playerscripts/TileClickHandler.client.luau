-- TileClickHandler (LocalScript in StarterPlayerScripts)
-- Detects when player clicks on map tiles and sends to server for NPC movement

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Player = Players.LocalPlayer
local Mouse = Player:GetMouse()

-- Wait for RemoteEvent
local NPCMoveToTileEvent = ReplicatedStorage:WaitForChild("NPCMoveToTileEvent", 10)

-- Get reference to EuropeMap
local EuropeMap = Workspace:WaitForChild("EuropeMap", 10)

-- Helper to check if a part is a tile (inside EuropeMap country models)
local function isTilePart(part)
	if not part or not part:IsA("BasePart") then return false end

	-- Parts directly under EuropeMap are not tiles
	if part.Parent == EuropeMap then return false end

	-- Walk up to check if this part is inside a country model
	local current = part.Parent
	while current and current ~= Workspace do
		if current.Parent == EuropeMap then
			-- Found a country model
			return true
		end
		current = current.Parent
	end
	return false
end

-- Helper to check if we clicked on an NPC (not a tile)
local function isNPCPart(part)
	if not part then return false end

	-- Walk up to find if this is part of an NPC model
	local current = part.Parent
	while current and current ~= Workspace do
		if current:IsA("Model") then
			-- Check if it has Humanoid (NPC indicator)
			if current:FindFirstChildOfClass("Humanoid") then
				return true
			end
		end
		current = current.Parent
	end
	return false
end

-- Handle mouse click
Mouse.Button1Down:Connect(function()
	local target = Mouse.Target

	if not target then return end

	-- Skip if we clicked on an NPC (handled by ClickDetector)
	if isNPCPart(target) then
		return
	end

	-- Check if we clicked on a tile
	if isTilePart(target) then
		-- Send tile click to server
		NPCMoveToTileEvent:FireServer(target)
	end
end)

print("[TileClickHandler] Initialized - listening for tile clicks")