-- TileVisualEffects (client)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local TileCapturedEvent = ReplicatedStorage:WaitForChild("TileCapturedEvent", 10)
local EUROPE_MAP = Workspace:WaitForChild("EuropeMap", 10)

-- Config
local TWEEN_TIME = 0.8 -- Duration of the color transition

-- Cache
local CountryColors = {}
-- ActiveTransitions: part -> { startColor: Color3, targetColor: Color3, elapsed: number }
local ActiveTransitions = {}

-- Helper: get a representative BasePart color for a country model
local function getFirstBasePartColor(countryModel)
	if not countryModel then return nil end

	local container = countryModel:FindFirstChild("Parts") or countryModel:FindFirstChild("Tiles")
	if container and typeof(container.GetChildren) == "function" then
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("BasePart") then
				return child.Color
			end
			if child:IsA("Model") or child:IsA("Folder") then
				for _, sub in ipairs(child:GetChildren()) do
					if sub:IsA("BasePart") then
						return sub.Color
					end
				end
			end
		end
	end

	for _, child in ipairs(countryModel:GetChildren()) do
		if child:IsA("BasePart") then
			return child.Color
		end
	end

	for _, desc in ipairs(countryModel:GetDescendants()) do
		if desc:IsA("BasePart") then
			return desc.Color
		end
	end

	return nil
end

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

-- Initialize and connect
scanCountryColors()

-- Task Scheduler Optimization Loop
local function onHeartbeat(dt)
	if not next(ActiveTransitions) then return end

	-- Optimization: Calculate all new colors in a single pass
	local updates = {}
	local toRemove = {}
	
	for part, data in pairs(ActiveTransitions) do
		data.elapsed += dt
		local alpha = math.clamp(data.elapsed / TWEEN_TIME, 0, 1)
		
		-- Use quadratic out easing: 1 - (1 - x)^2
		local easeAlpha = 1 - (1 - alpha) * (1 - alpha)
		local newColor = data.startColor:Lerp(data.targetColor, easeAlpha)
		
		updates[part] = newColor
		
		if alpha >= 1 then
			table.insert(toRemove, part)
		end
	end
	
	-- Apply property changes in a batch
	for part, color in pairs(updates) do
		if part.Parent then
			part.Color = color
		end
	end
	
	for _, part in ipairs(toRemove) do
		ActiveTransitions[part] = nil
	end
end

RunService.Heartbeat:Connect(onHeartbeat)

local function onTileCaptured(tilePartOrBatch, playerName, countryName)
	if not tilePartOrBatch or not countryName then return end
	
	local targetColor = CountryColors[countryName]
	if not targetColor then return end

	local function registerPart(part)
		if not part:IsA("BasePart") then return end
		if part.Color == targetColor then return end
		
		ActiveTransitions[part] = {
			startColor = part.Color,
			targetColor = targetColor,
			elapsed = 0
		}
	end

	if typeof(tilePartOrBatch) == "table" then
		for _, tilePart in ipairs(tilePartOrBatch) do
			registerPart(tilePart)
		end
	else
		registerPart(tilePartOrBatch)
	end
end

TileCapturedEvent.OnClientEvent:Connect(onTileCaptured)

print("[TileVisualEffects] Batched color transitions active.")

