-- LocalScript: NPCVisualsHandler (Place in StarterPlayerScripts)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local SelectionVisualEvent = ReplicatedStorage:WaitForChild("SelectionVisualEvent", 10)

-- Config
local SELECTION_COLOR = Color3.fromRGB(0, 255, 0)
local HIGHLIGHT_TRANSPARENCY = 0.8

-- State
local SelectedNPCs = {} -- npcModel -> true
local Highlighting = {} -- npcModel -> Highlight

-- Optimization: Track all NPCs to handle bulk updates if needed
local RegisteredNPCs = {}

local function createHighlight(npcModel)
	local highlight = Instance.new("Highlight")
	highlight.FillColor = SELECTION_COLOR
	highlight.OutlineColor = SELECTION_COLOR
	highlight.Adornee = npcModel
	highlight.FillTransparency = HIGHLIGHT_TRANSPARENCY
	highlight.Enabled = true
	highlight.Parent = npcModel
	return highlight
end

local function toggleHighlight(npcModel, shouldHighlight)
	if not npcModel or not npcModel.Parent then return end

	if shouldHighlight then
		SelectedNPCs[npcModel] = true
		if not Highlighting[npcModel] then
			Highlighting[npcModel] = createHighlight(npcModel)
			
			-- Clean up when NPC is destroyed
			npcModel.Destroying:Once(function()
				Highlighting[npcModel] = nil
				SelectedNPCs[npcModel] = nil
			end)
		else
			Highlighting[npcModel].Enabled = true
		end
	else
		SelectedNPCs[npcModel] = nil
		if Highlighting[npcModel] then
			Highlighting[npcModel].Enabled = false
		end
	end
end

-- Task Scheduler Optimization Loop
local function onHeartbeat(_dt)
	-- Serial phase: Apply visual updates
	-- If we had custom selection rings (Parts), we would use BulkMoveTo here:
	-- workspace:BulkMoveTo(models, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end

RunService.Heartbeat:Connect(onHeartbeat)

SelectionVisualEvent.OnClientEvent:Connect(function(npcModel, shouldHighlight)
	toggleHighlight(npcModel, shouldHighlight)
end)

-- Initialize with existing NPCs
for _, npc in ipairs(CollectionService:GetTagged("RegisteredNPC")) do
	RegisteredNPCs[npc] = true
end

CollectionService:GetInstanceAddedSignal("RegisteredNPC"):Connect(function(npc)
	RegisteredNPCs[npc] = true
end)

CollectionService:GetInstanceRemovedSignal("RegisteredNPC"):Connect(function(npc)
	RegisteredNPCs[npc] = nil
	if Highlighting[npc] then
		Highlighting[npc]:Destroy()
		Highlighting[npc] = nil
	end
	SelectedNPCs[npc] = nil
end)

print("[NPCVisualsHandler] Task-optimized visuals active.")
