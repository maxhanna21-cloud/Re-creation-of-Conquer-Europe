-- LocalScript: NPCVisualsHandler (Place in StarterPlayerScripts)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SelectionVisualEvent = ReplicatedStorage:WaitForChild("SelectionVisualEvent", 10)

local Highlighting = {}

local SELECTION_COLOR = Color3.fromRGB(0, 255, 0)

local function toggleHighlight(npcModel, shouldHighlight)
	if not npcModel or not npcModel.Parent then return end

	local existingHighlight = Highlighting[npcModel]

	if shouldHighlight then
		if not existingHighlight then
			local highlight = Instance.new("Highlight")
			highlight.FillColor = SELECTION_COLOR
			highlight.OutlineColor = SELECTION_COLOR
			highlight.Adornee = npcModel
			highlight.Parent = npcModel
			highlight.FillTransparency = 0.8
			Highlighting[npcModel] = highlight

			-- Clean up table entry when NPC is destroyed
			npcModel.Destroying:Once(function()
				Highlighting[npcModel] = nil
			end)
		end
	else
		if existingHighlight then
			existingHighlight:Destroy()
			Highlighting[npcModel] = nil
		end
	end
end

SelectionVisualEvent.OnClientEvent:Connect(function(npcModel, shouldHighlight)
	toggleHighlight(npcModel, shouldHighlight)
end)
