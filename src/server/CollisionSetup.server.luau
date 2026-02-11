-- CollisionSetup (ServerScriptService)
-- Run once at server start to configure collision groups

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

-- Create collision groups
PhysicsService:RegisterCollisionGroup("NPCs")
PhysicsService:RegisterCollisionGroup("Players")

-- NPCs don't collide with NPCs
PhysicsService:CollisionGroupSetCollidable("NPCs", "NPCs", false)

-- NPCs don't collide with Players
PhysicsService:CollisionGroupSetCollidable("NPCs", "Players", false)

-- Helper to set collision group on all parts
local function setCollisionGroup(model, groupName)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CollisionGroup = groupName
		end
	end
	-- Also check the model itself if it's a BasePart
	if model:IsA("BasePart") then
		model.CollisionGroup = groupName
	end
end

-- Assign players to "Players" group when their character spawns
local function onCharacterAdded(character)
	-- Wait for the character to fully load
	local humanoidRootPart = character:WaitForChild("HumanoidRootPart", 5)
	if not humanoidRootPart then
		warn("[CollisionSetup] HumanoidRootPart not found for " .. character.Name .. " after 5 seconds")
		return
	end
	setCollisionGroup(character, "Players")

	-- Handle parts added later (accessories, tools, etc.)
	character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = "Players"
		end
	end)
end

local function onPlayerAdded(player)
	-- Handle current character
	if player.Character then
		onCharacterAdded(player.Character)
	end

	-- Handle future characters (respawns)
	player.CharacterAdded:Connect(onCharacterAdded)
end

-- Setup existing players
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

-- Setup new players
Players.PlayerAdded:Connect(onPlayerAdded)

print("[CollisionSetup] Collision groups configured")