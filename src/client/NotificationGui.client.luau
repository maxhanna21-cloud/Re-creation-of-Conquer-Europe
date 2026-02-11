-- LocalScript inside NotificationGui
-- FIX: Added debounce to prevent notification overlap when multiple arrive rapidly
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GlobalNotificationEvent = ReplicatedStorage:WaitForChild("GlobalNotificationEvent", 10)

local frame = script.Parent:WaitForChild("AlertFrame")
local label = frame:WaitForChild("AlertText")

-- Track the current notification ID to cancel old hide timers
local currentNotificationId = 0

GlobalNotificationEvent.OnClientEvent:Connect(function(message, color)
	-- Increment notification ID to invalidate previous hide timer
	currentNotificationId = currentNotificationId + 1
	local thisNotificationId = currentNotificationId

	label.Text = message
	label.TextColor3 = color

	frame.Visible = true

	-- Play a sound here if you have one!

	task.wait(5) -- Show for 5 seconds

	-- Only hide if this is still the most recent notification
	if currentNotificationId == thisNotificationId then
		frame.Visible = false
	end
end)
