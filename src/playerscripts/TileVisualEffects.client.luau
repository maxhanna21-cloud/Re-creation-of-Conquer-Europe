-- TileVisualEffects (client)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local TileCapturedEvent = ReplicatedStorage:WaitForChild("TileCapturedEvent", 10)
local EUROPE_MAP = Workspace:WaitForChild("EuropeMap", 10)

-- Config
local TWEEN_TIME = 0.8 -- Duration of the color transition

-- Cache & active tween tracker (weak keys so destroyed parts can be collected)
local CountryColors = {}
local ActiveTweens = setmetatable({}, { __mode = "k" }) -- weak keys

-- Helper: get a representative BasePart color for a country model
local function getFirstBasePartColor(countryModel)
	if not countryModel then return nil end

	-- Prefer a well-known container if present (reduce work & avoid decorations)
	local container = countryModel:FindFirstChild("Parts") or countryModel:FindFirstChild("Tiles")
	if container and typeof(container.GetChildren) == "function" then
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("BasePart") then
				return child.Color
			end
			-- quick shallow check for nested model/folder
			if child:IsA("Model") or child:IsA("Folder") then
				for _, sub in ipairs(child:GetChildren()) do
					if sub:IsA("BasePart") then
						return sub.Color
					end
				end
			end
		end
	end

	-- Fall back to checking direct children of the model (cheaper than full descendants)
	for _, child in ipairs(countryModel:GetChildren()) do
		if child:IsA("BasePart") then
			return child.Color
		end
	end

	-- Last resort: descendants (use sparingly)
	for _, desc in ipairs(countryModel:GetDescendants()) do
		if desc:IsA("BasePart") then
			return desc.Color
		end
	end

	return nil
end

-- Initialize country colors once at startup from the map's original tile colors.
-- CountryColors is intentionally immutable after this point — updating it from live
-- tile colors during gameplay would corrupt lookups once tiles are captured/repainted.
local function scanCountryColors()
	for _, countryModel in ipairs(EUROPE_MAP:GetChildren()) do
		if countryModel:IsA("Model") then
			local countryName = countryModel.Name
			local color = getFirstBasePartColor(countryModel)
			if color then
				CountryColors[countryName] = color
			end
		end
	end
end

-- Main handler: tween tilePart to the country's color
local function onTileCaptured(tilePart, playerName, countryName)
	-- Basic validation
	if not tilePart or not countryName then
		return
	end
	if not tilePart:IsA("BasePart") then
		return
	end

	-- Resolve target color from the startup cache.
	-- Do NOT read live tile colors here — tiles may already be repainted by the server,
	-- and sampling them would corrupt the cache with occupying-country colors.
	local targetColor = CountryColors[countryName]

	if not targetColor then
		-- Nothing we can do visually if we don't have a color
		return
	end

	-- Skip if already the same color
	if tilePart.Color == targetColor then
		return
	end

	-- Cancel any existing tween on this part to avoid stacking/jitter
	local existing = ActiveTweens[tilePart]
	if existing then
		-- Cancel the running tween and clear it from the tracker
		-- Tween:Cancel() exists on Roblox Tween objects
		pcall(function()
			existing:Cancel()
		end)
		ActiveTweens[tilePart] = nil
	end

	-- Create and play the tween
	local tweenInfo = TweenInfo.new(TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(tilePart, tweenInfo, { Color = targetColor })

	-- Track the tween and clear reference when it's done (completed or cancelled)
	ActiveTweens[tilePart] = tween
	tween.Completed:Connect(function(playbackState)
		-- Only clear if this same tween is still tracked (defensive)
		if ActiveTweens[tilePart] == tween then
			ActiveTweens[tilePart] = nil
		end
	end)

	tween:Play()
end

-- Initialize and connect
scanCountryColors()
TileCapturedEvent.OnClientEvent:Connect(onTileCaptured)

print("[TileVisualEffects] Smooth color transitions active.")