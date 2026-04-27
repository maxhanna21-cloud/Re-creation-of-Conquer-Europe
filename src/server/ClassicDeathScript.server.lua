-- ClassicDeathScript (ServerScriptService)
-- Restores the legacy "explode on death" animation. Roblox now defaults
-- BreakJointsOnDeath to false in favor of ragdoll; this script forces the
-- old behavior and schedules limb cleanup so dead parts don't accumulate.

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local LIMB_LIFETIME = 5
local POP_HORIZONTAL_MIN, POP_HORIZONTAL_MAX = -5, 5
local POP_VERTICAL_MIN, POP_VERTICAL_MAX = 5, 10

-- player -> { charAdded = RBXScriptConnection, died = RBXScriptConnection? }
local connections = {}

local function onCharacterAdded(player, character)
	local entry = connections[player]
	if not entry then return end

	-- Drop the previous character's Died binding before rebinding.
	if entry.died then
		entry.died:Disconnect()
		entry.died = nil
	end

	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid then return end

	humanoid.BreakJointsOnDeath = true

	entry.died = humanoid.Died:Connect(function()
		-- Brief yield: lets the engine finish its own death bookkeeping
		-- before we forcibly break joints, otherwise the call can no-op.
		task.wait()
		if not character.Parent then return end

		character:BreakJoints()

		for _, part in ipairs(character:GetChildren()) do
			if part:IsA("BasePart") then
				part.AssemblyLinearVelocity = Vector3.new(
					math.random(POP_HORIZONTAL_MIN, POP_HORIZONTAL_MAX),
					math.random(POP_VERTICAL_MIN, POP_VERTICAL_MAX),
					math.random(POP_HORIZONTAL_MIN, POP_HORIZONTAL_MAX)
				)
				Debris:AddItem(part, LIMB_LIFETIME)
			end
		end
	end)
end

local function onPlayerAdded(player)
	connections[player] = { charAdded = nil, died = nil }

	connections[player].charAdded = player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)

	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end

Players.PlayerRemoving:Connect(function(player)
	local entry = connections[player]
	if entry then
		if entry.charAdded then entry.charAdded:Disconnect() end
		if entry.died then entry.died:Disconnect() end
		connections[player] = nil
	end
end)

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end
