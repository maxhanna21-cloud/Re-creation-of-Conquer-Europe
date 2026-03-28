-- LocalScript inside NotificationGui
-- UPDATED: Added a Queueing System and TweenService Animations
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local GlobalNotificationEvent = ReplicatedStorage:WaitForChild("GlobalNotificationEvent", 10)

local frame = script.Parent:WaitForChild("AlertFrame")
local label = frame:WaitForChild("AlertText")

-- Animation & Timing Configuration
local DISPLAY_TIME = 4.0      -- How long the notification stays on screen
local TWEEN_DURATION = 0.5    -- How long the slide in/out animation takes

-- Capture the original layout position to use as the "on-screen" target
local ON_SCREEN_POS = frame.Position
-- Calculate an "off-screen" position (slides up by 15% of screen height)
local OFF_SCREEN_POS = ON_SCREEN_POS - UDim2.new(0, 0, 0.15, 0)

-- Set initial state
frame.Position = OFF_SCREEN_POS
frame.Visible = false

-- Queue State
local notificationQueue = {}
local isPlaying = false

-- Function to process the queue sequentially
local function processQueue()
	-- If a notification is already playing, or the queue is empty, do nothing
	if isPlaying or #notificationQueue == 0 then return end
	isPlaying = true

	-- Grab the oldest notification from the front of the queue
	local currentAlert = table.remove(notificationQueue, 1)

	-- 1. Setup UI
	label.Text = currentAlert.message
	label.TextColor3 = currentAlert.color
	frame.Position = OFF_SCREEN_POS
	frame.Visible = true

	-- 2. Slide In Animation (using 'Back' for a nice pop effect)
	local tweenInInfo = TweenInfo.new(TWEEN_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local tweenIn = TweenService:Create(frame, tweenInInfo, {Position = ON_SCREEN_POS})
	
	-- Optional: Play a sound here!
	-- local sound = script.Parent:FindFirstChild("AlertSound")
	-- if sound then sound:Play() end
	
	tweenIn:Play()
	tweenIn.Completed:Wait() -- Wait for slide-in to finish

	-- 3. Hold on screen
	task.wait(DISPLAY_TIME)

	-- 4. Slide Out Animation
	local tweenOutInfo = TweenInfo.new(TWEEN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local tweenOut = TweenService:Create(frame, tweenOutInfo, {Position = OFF_SCREEN_POS})
	
	tweenOut:Play()
	tweenOut.Completed:Wait() -- Wait for slide-out to finish

	-- 5. Cleanup and check for more
	frame.Visible = false
	isPlaying = false

	-- If there are more notifications waiting, process them immediately
	if #notificationQueue > 0 then
		task.defer(processQueue)
	end
end

-- Listen for global events
GlobalNotificationEvent.OnClientEvent:Connect(function(message, color)
	-- Add to the queue
	table.insert(notificationQueue, {
		message = message,
		color = color
	})

	-- Attempt to process the queue
	processQueue()
end)
