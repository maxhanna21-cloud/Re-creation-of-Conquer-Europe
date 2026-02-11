-- LeaderstatsSetup
local Players = game:GetService("Players")

local function setupLeaderstats(player)
	-- Check if leaderstats already exists to prevent duplication
	if player:FindFirstChild("leaderstats") then
		return
	end

	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"

	local Coins = Instance.new("IntValue")
	Coins.Name = "Coins"
	Coins.Value = 0

	local Manpower = Instance.new("IntValue")
	Manpower.Name = "Manpower"
	Manpower.Value = 0

	local Country = Instance.new("StringValue")
	Country.Name = "Country"
	Country.Value = "None"

	-- Parent last for performance best practices
	Coins.Parent = leaderstats
	Manpower.Parent = leaderstats
	Country.Parent = leaderstats
	leaderstats.Parent = player
end

-- Connect for future players
Players.PlayerAdded:Connect(setupLeaderstats)

-- Handle players already in the game (fixes race condition)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(setupLeaderstats, player)
end