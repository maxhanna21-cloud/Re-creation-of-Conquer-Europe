-- LocalScript inside BuyNPCGui
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BuyNPCEvent = ReplicatedStorage:WaitForChild("BuyNPCEvent", 10)

local player = game.Players.LocalPlayer
local gui = script.Parent

local mainFrame = gui:WaitForChild("MainFrame", 10)
local attackerBtn = mainFrame:WaitForChild("BuyAttackerButton", 10)
local defenderBtn = mainFrame:WaitForChild("BuyDefenderButton", 10)

attackerBtn.MouseButton1Click:Connect(function()
	BuyNPCEvent:FireServer("AttackerNPC")
end)

defenderBtn.MouseButton1Click:Connect(function()
	BuyNPCEvent:FireServer("DefenderNPC")
end)