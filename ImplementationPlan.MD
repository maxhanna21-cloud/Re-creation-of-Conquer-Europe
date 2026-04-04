# Conquer Europe — Low-End Device Optimization Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce CPU, memory, and network overhead so the game runs smoothly on older/lower-end devices (mobile, low-spec PCs, older consoles).

**Architecture:** Six independent optimization passes targeting the highest-impact bottlenecks: laser beam Part allocation (GC pressure), per-NPC Heartbeat connection sprawl (CPU), per-NPC combat thread sprawl (scheduler), per-tile remote event spam (network), client-side cache eviction spikes (frame drops), and an adaptive NPC LOD system that scales processing cost with NPC count.

**Tech Stack:** Roblox Luau, RunService (Heartbeat/RenderStepped), CollectionService, Debris, TweenService, RemoteEvents/UnreliableRemoteEvents

---

## NON-NEGOTIABLE RULES (from CLAUDE.md — apply to every task)

- NEVER use `wait()`, `spawn()`, or `delay()` — use `task.wait`, `task.spawn`, `task.defer`.
- NEVER use `GetDescendants` in runtime loops — startup/init only.
- ALWAYS defend against nil (StreamingEnabled).
- Every per-NPC signal MUST have explicit cleanup (disconnect + nil table refs).
- No `--!strict` unless user requests it.
- Full scripts only — no snippets, no "rest unchanged."
- Consistent tab indentation, proper `end` alignment.

---

## File Structure Overview

| File | Changes | Responsibility |
|------|---------|----------------|
| `src/shared/NPCCombatSystem.luau` | Task 1 (beam pool), Task 3 (combat loop consolidation) | Combat VFX + combat tick scheduling |
| `src/shared/NPCMovementSystem.luau` | Task 2 (Heartbeat consolidation) | NPC ground checks + movement monitoring |
| `src/playerscripts/TileCursor.client.luau` | Task 5 (cache eviction) | Tile hover detection LRU cache |
| `src/shared/TileOwnershipManager.luau` | Task 4 (batch events) | Tile capture/release remote events |
| `src/playerscripts/TileVisualEffects.client.luau` | Task 4 (batch handler) | Client-side tile color transitions |
| `src/shared/NPCLODManager.luau` (NEW) | Task 6 (NPC LOD) | Adaptive NPC processing throttle |

---

## Task 1: Laser Beam Part Pooling

**Problem:** `createLaserBeam()` in NPCCombatSystem allocates a new `Part` instance every shot and relies on `Debris` to destroy it 0.1s later. With N NPCs firing at 1 shot/sec, the engine creates and destroys N Parts/sec — heavy GC pressure on low-end devices.

**Solution:** Pre-allocate a pool of reusable beam Parts. On fire: grab from pool, position, make visible. On expiry: hide, return to pool. Zero runtime allocation after warmup.

**Files:**
- Modify: `src/shared/NPCCombatSystem.luau` (lines 209–221: `createLaserBeam`, lines 224–250: `fireMultiLaser`)

### REJECTED ALTERNATIVES
1. **Use Beams (Attachment-based):** Requires two Attachments parented to different Parts — more complex, same allocation issue if not pooled, and Beam rendering is heavier than a thin neon Part.
2. **Use BillboardGui with ImageLabel:** Lower fidelity, doesn't orient correctly in 3D space for laser effects.
3. **Reduce fire rate globally:** Degrades gameplay feel; pooling solves the root cause without changing mechanics.

### SCALABILITY CHECK
- Pool size scales with max concurrent beams: `MAX_POOL_SIZE = math.ceil(MAX_EXPECTED_NPCS * 1.2)` to handle multi-target split fire.
- If pool is exhausted, oldest active beam is recycled (not allocated fresh).
- Pool cleanup on game end: iterate and Destroy all pooled Parts.

### FAILURE SIMULATION
- Pool empty + 50 NPCs fire simultaneously → recycled beam appears to teleport (acceptable visual glitch, no allocation).
- NPC destroyed mid-beam → beam returns to pool on its timer regardless of NPC state.
- Server lag causes beam to persist longer than 0.1s → no harm, `task.delay` handles it.

---

- [ ] **Step 1: Add beam pool data structures at module top**

Add after the existing `local debugParts = {}` block (around line 64):

```lua
-- Beam object pool — avoids per-shot Part allocation
local BEAM_POOL_SIZE = 120 -- enough for ~100 NPCs firing simultaneously
local beamPool = {}        -- available (hidden) beam Parts
local activeBeams = {}     -- currently visible beam Parts (keyed by Part)

local function createPooledBeamPart()
	local beam = Instance.new("Part")
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CanTouch = false
	beam.CastShadow = false
	beam.Material = Enum.Material.Neon
	beam.Size = Vector3.new(0.2, 0.2, 1)
	beam.Transparency = 1 -- hidden until needed
	beam.Parent = workspace
	return beam
end

local function initBeamPool()
	for i = 1, BEAM_POOL_SIZE do
		table.insert(beamPool, createPooledBeamPart())
	end
end
```

- [ ] **Step 2: Add acquire/release helpers**

```lua
local function acquireBeam()
	local beam = table.remove(beamPool)
	if not beam then
		-- Pool exhausted: recycle oldest active beam
		local oldest, oldestKey = nil, nil
		for b, _ in pairs(activeBeams) do
			oldest = b
			oldestKey = b
			break -- pick an arbitrary active beam to recycle (pairs order is not guaranteed)
		end
		if oldest then
			oldest.Transparency = 1
			activeBeams[oldestKey] = nil
			beam = oldest
		else
			-- Absolute fallback: create one (should rarely happen)
			beam = createPooledBeamPart()
		end
	end
	return beam
end

local function releaseBeam(beam)
	if not beam or not beam.Parent then return end
	beam.Transparency = 1
	activeBeams[beam] = nil
	table.insert(beamPool, beam)
end
```

- [ ] **Step 3: Replace `createLaserBeam` with pooled version**

Replace the existing `createLaserBeam` function (lines 209–221):

```lua
local function createLaserBeam(originPos, targetPos, color)
	local distance = (targetPos - originPos).Magnitude
	local beam = acquireBeam()
	beam.Color = color or Color3.fromRGB(255, 0, 0)
	beam.Size = Vector3.new(0.2, 0.2, distance)
	beam.CFrame = CFrame.lookAt(originPos, targetPos) * CFrame.new(0, 0, -distance / 2)
	beam.Transparency = 0
	activeBeams[beam] = true
	task.delay(BEAM_LIFETIME, function()
		releaseBeam(beam)
	end)
end
```

- [ ] **Step 4: Call `initBeamPool()` at module initialization**

Add at the bottom of the module, before the `return Combat` line:

```lua
initBeamPool()
```

- [ ] **Step 5: Add pool cleanup to module (memory leak prevention)**

Add a cleanup function that the NPC lifecycle can call if the combat system is torn down:

```lua
function Combat.destroyBeamPool()
	for _, beam in ipairs(beamPool) do
		beam:Destroy()
	end
	table.clear(beamPool)
	for beam, _ in pairs(activeBeams) do
		beam:Destroy()
	end
	table.clear(activeBeams)
end
```

- [ ] **Step 6: Test in-game**

1. Spawn 10+ NPCs in adjacent enemy tiles so combat triggers.
2. Observe laser beams firing — they should look identical to before.
3. Open Roblox Developer Console → check Instance count is stable (not climbing).
4. Confirm beams appear and disappear correctly with 0.1s lifetime.

- [ ] **Step 7: Remove old Debris import if unused elsewhere**

Check if `Debris` is still used by other functions (e.g., `drawDebugLine`). If `drawDebugLine` is the only other user and `DEBUG` is false in production, consider pooling debug lines too or leaving Debris for debug-only use.

- [ ] **Step 8: Commit**

```bash
git add src/shared/NPCCombatSystem.luau
git commit -m "perf: pool laser beam Parts to eliminate per-shot allocation"
```

---

## Task 2: Consolidate Per-NPC Heartbeat Connections

**Problem:** NPCMovementSystem creates up to 3 separate `RunService.Heartbeat:Connect()` calls per NPC: ground check (line 1130), movement monitor, and follow-movement monitor. With 100 NPCs, that's 300 active RBXScriptConnections firing every frame — significant overhead on low-end devices.

**Solution:** Replace per-NPC Heartbeat connections with a single global Heartbeat loop that iterates a registry of active NPCs. Each NPC gets processed once per tick through a unified update function.

**Scope note:** This task consolidates the **ground check** Heartbeat connections (the most impactful — fires for ALL NPCs including idle ones). The movement monitor and follow-movement monitor connections are shorter-lived (only active during actual movement) and can be consolidated in a follow-up pass if needed. Ground checks are the priority because they run for every NPC at all times.

**Files:**
- Modify: `src/shared/NPCMovementSystem.luau` (lines 1125–1183: `startGroundCheck`, movement monitor connections, follow-movement connections)

### REJECTED ALTERNATIVES
1. **Reduce ground check frequency to 1s:** Doesn't fix the connection count problem; NPCs can fall off tiles in <1s.
2. **Use task.spawn loops instead of Heartbeat:** Trades connection overhead for thread scheduling overhead — lateral move.
3. **Only check ground for moving NPCs:** Idle NPCs can still drift or be pushed off tiles by physics; need checking.

### SCALABILITY CHECK
- Single Heartbeat connection = O(1) connection overhead regardless of NPC count.
- Inner loop is O(N) but with early-exit per NPC (skip if accumulator hasn't elapsed).
- Ground check remains at 0.1s interval per NPC; movement checks remain per-frame for moving NPCs only.

### FAILURE SIMULATION
- NPC destroyed during iteration → `if not npcModel or not npcModel.Parent then remove from registry, continue`.
- NPC registered twice → registry uses npcModel as key (dict), not array — idempotent.
- All NPCs removed → loop iterates empty table, negligible cost.

---

- [ ] **Step 1: Add global NPC movement registry at module top**

Add near the top of NPCMovementSystem, after existing local declarations:

```lua
-- Global movement registry: single Heartbeat drives all NPCs
-- registeredNPCs[npcModel] = { groundAccum = 0, isMoving = false, isFollowing = false }
local registeredNPCs = {}
local heartbeatConnection = nil
```

- [ ] **Step 2: Create unified Heartbeat tick function**

```lua
local function onMovementHeartbeat(dt)
	for npcModel, reg in pairs(registeredNPCs) do
		if not npcModel or not npcModel.Parent then
			-- NPC was destroyed — clean up
			registeredNPCs[npcModel] = nil
			if groundCheckConnections[npcModel] then
				groundCheckConnections[npcModel]:Disconnect()
				groundCheckConnections[npcModel] = nil
			end
			continue
		end

		-- Ground check (throttled to GROUND_CHECK_INTERVAL)
		reg.groundAccum = reg.groundAccum + dt
		if reg.groundAccum >= GROUND_CHECK_INTERVAL then
			reg.groundAccum = 0

			if not isOnValidGround(npcModel) then
				if DEBUG then
					print("[NPCMovement:GroundCheck] Triggering teleport recovery for " .. npcModel.Name)
				end
				teleportToSafeTile(npcModel)
			else
				-- Snap idle drifters (same logic as existing startGroundCheck)
				local state = NPCMovementSystem.getMovementState(npcModel)
				if state == "Idle" then
					local root = getRootPart(npcModel)
					local tileKey = npcModel:GetAttribute("TileKey")
					if root and tileKey then
						local tilePart = TileAdjacencyManager.getTileFromKey(tileKey)
						if tilePart then
							local safePos = getTileSpawnPosition(tilePart)
							if safePos then
								local driftXZ = ((root.Position - safePos) * Vector3.new(1, 0, 1)).Magnitude
								local stateData = movementStates[npcModel]
								local timeSinceStop = os.clock() - (stateData and stateData.lastStopTime or 0)
								local timeSinceNudge = os.clock() - (stateData and stateData.lastNudgeTime or 0)
								if driftXZ > IDLE_DRIFT_THRESHOLD and timeSinceStop > 1.0 and timeSinceNudge > 4.0 then
									if DEBUG then
										print("[NPCMovement:GroundCheck] Idle NPC " .. npcModel.Name .. " is " .. string.format("%.1f", driftXZ) .. " studs from center, walking back")
									end
									root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
									local humanoid = getHumanoid(npcModel)
									if humanoid then humanoid:MoveTo(safePos) end
									if stateData then stateData.lastNudgeTime = os.clock() end
								end
							end
						end
					end
				end
			end
		end
	end
end
```

- [ ] **Step 3: Start/stop the single Heartbeat connection**

```lua
local function ensureHeartbeatRunning()
	if not heartbeatConnection then
		heartbeatConnection = RunService.Heartbeat:Connect(onMovementHeartbeat)
	end
end

local function stopHeartbeatIfEmpty()
	if heartbeatConnection and not next(registeredNPCs) then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
end
```

- [ ] **Step 4: Refactor `startGroundCheck` to register instead of connect**

Replace the existing `startGroundCheck` function:

```lua
local function startGroundCheck(npcModel)
	if registeredNPCs[npcModel] then return end -- already registered
	registeredNPCs[npcModel] = { groundAccum = 0 }
	ensureHeartbeatRunning()
end
```

- [ ] **Step 5: Update NPC cleanup to unregister from global loop**

Find all places where `groundCheckConnections[npcModel]` is disconnected and add:

```lua
registeredNPCs[npcModel] = nil
stopHeartbeatIfEmpty()
```

- [ ] **Step 6: Test in-game**

1. Spawn 20+ NPCs across multiple countries.
2. Verify ground checks still work: push an NPC off a tile edge → it should teleport back.
3. Verify idle drift correction: an idle NPC that drifts should walk back to center.
4. Open Developer Console → confirm only 1 Heartbeat connection exists for movement (not N).

- [ ] **Step 7: Commit**

```bash
git add src/shared/NPCMovementSystem.luau
git commit -m "perf: consolidate per-NPC Heartbeat connections into single global loop"
```

---

## Task 3: Consolidate Combat Loop Threads

**Problem:** `startCombatLoop()` calls `task.spawn()` per NPC, creating a dedicated coroutine per active combatant. With 100 NPCs in combat, the Luau scheduler manages 100 yielding threads — each calling `task.wait(0.1)` 10 times/sec.

**Solution:** Replace per-NPC `task.spawn` loops with a single global combat tick driven by a Heartbeat connection with a 0.1s accumulator. Process all combat NPCs in one pass.

**Files:**
- Modify: `src/shared/NPCCombatSystem.luau` (lines 292–377: `startCombatLoop`)

### REJECTED ALTERNATIVES
1. **Keep task.spawn but increase LOOP_WAIT:** Degrades combat responsiveness; doesn't fix thread count.
2. **Use BindToRenderStep:** Combat is server-side; RenderStepped is client-only.
3. **Batch NPCs into groups of 10:** Adds complexity without eliminating the core problem.

### SCALABILITY CHECK
- Single Heartbeat connection regardless of NPC count.
- Inner loop processes only NPCs with `combatLoops[npc] ~= nil`.
- Token-based generation tracking still works — stale entries are skipped and cleaned.

### FAILURE SIMULATION
- NPC destroyed during combat tick → `npcModel.Parent` check, skip and unregister.
- NPC re-registered mid-tick → token mismatch on old entry, new entry processed next tick.
- Zero combat NPCs → loop iterates empty table, negligible cost.

---

- [ ] **Step 1: Add global combat registry and tick infrastructure**

Add after the existing internal tables block:

```lua
-- Global combat tick: single Heartbeat replaces per-NPC task.spawn loops
-- combatRegistry[npcModel] = { token = {}, getAllTargets = fn, beamColor = Color3, lastShot = 0 }
local combatRegistry = {}
local combatTickConnection = nil
local combatAccumulator = 0
```

- [ ] **Step 2: Create unified combat tick function**

```lua
local function onCombatTick(dt)
	combatAccumulator = combatAccumulator + dt
	if combatAccumulator < LOOP_WAIT then return end
	combatAccumulator = 0

	local now = os.clock()
	for npcModel, reg in pairs(combatRegistry) do
		-- Validity check
		if not npcModel or not npcModel.Parent then
			combatRegistry[npcModel] = nil
			combatLoops[npcModel] = nil
			continue
		end

		-- Token check (re-registration invalidates old entry)
		if combatLoops[npcModel] ~= reg.token then
			combatRegistry[npcModel] = nil
			continue
		end

		local humanoid = npcModel:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			-- Stop processing this NPC in the combat tick.
			-- Do NOT call Combat.unregisterNPC here — the Maid's Humanoid.Died
			-- connection (set up in registerNPC) handles full cleanup including
			-- table clearing and connection disconnection. Calling unregister here
			-- would race with the Maid and could double-clean.
			combatRegistry[npcModel] = nil
			combatLoops[npcModel] = nil
			continue
		end

		local allTargets = reg.getAllTargets()
		updateCombatHealthState(npcModel, #allTargets > 0)

		if not hasActivePlayerOwner(npcModel) and #allTargets == 0 then
			local root = getRootPart(npcModel)
			if root then humanoid:MoveTo(root.Position) end
			continue
		end

		if #allTargets > 0 then
			local npcRoot = getRootPart(npcModel)
			if npcRoot then
				humanoid:MoveTo(npcRoot.Position)

				local firstTarget = allTargets[1]
				if firstTarget and firstTarget.Parent then
					local targetRoot = getRootPart(firstTarget.Parent)
					if targetRoot then
						local targetPos = targetRoot.Position
						local selfPos = npcRoot.Position
						local lookAtCFrame = CFrame.lookAt(selfPos, Vector3.new(targetPos.X, selfPos.Y, targetPos.Z))
						npcRoot.CFrame = CFrame.new(npcRoot.CFrame.Position) * (lookAtCFrame - lookAtCFrame.Position)
					end
				end

				local lastShot = npcCooldown[npcModel] or 0
				if now - lastShot >= SHOOT_INTERVAL then
					fireMultiLaser(npcModel, allTargets, reg.beamColor)
					npcCooldown[npcModel] = now
				end
			end
		else
			if DEBUG then
				local targetKey = npcModel.Name .. "_Target"
				if debugParts[targetKey] then
					debugParts[targetKey]:Destroy()
					debugParts[targetKey] = nil
				end
			end
			local root = getRootPart(npcModel)
			if root then humanoid:MoveTo(root.Position) end
		end
	end

	-- Stop connection if no combat NPCs
	if not next(combatRegistry) and combatTickConnection then
		combatTickConnection:Disconnect()
		combatTickConnection = nil
	end
end
```

- [ ] **Step 3: Refactor `startCombatLoop` to register instead of spawn**

Replace the existing `startCombatLoop` function:

```lua
local function startCombatLoop(npcModel, getAllTargets, beamColor)
	if not npcModel then return end
	if combatLoops[npcModel] then return end

	local token = {}
	combatLoops[npcModel] = token

	combatRegistry[npcModel] = {
		token = token,
		getAllTargets = getAllTargets,
		beamColor = beamColor,
	}

	if not combatTickConnection then
		combatAccumulator = 0
		combatTickConnection = RunService.Heartbeat:Connect(onCombatTick)
	end
end
```

- [ ] **Step 4: Update `unregisterNPC` to clear combat registry entry**

In the existing `unregisterNPC` function, add after the maid cleanup and before clearing combat tables:

```lua
combatRegistry[npcModel] = nil
```

- [ ] **Step 5: Test in-game**

1. Declare war between two adjacent countries.
2. Verify NPCs engage in combat — lasers fire, damage applies, NPCs face targets.
3. Kill an NPC → verify it's cleaned from combat registry (no errors).
4. Transfer ownership mid-combat → verify token invalidation works.
5. Check Developer Console for thread count — should be dramatically lower.

- [ ] **Step 6: Commit**

```bash
git add src/shared/NPCCombatSystem.luau
git commit -m "perf: replace per-NPC combat threads with single global combat tick"
```

---

## Task 4: Batch Tile Capture Remote Events

**Problem:** `captureTile()` and `releaseTile()` each fire `TileCapturedEvent:FireAllClients()` individually per tile. During intense combat with many NPCs capturing tiles simultaneously, this generates a burst of remote events. `performCountryTakeover` already batches — but the per-tile combat capture path does not.

**Solution:** Introduce a short accumulation window (0.1s) that collects tile capture events and fires them as a single batched array. Update the client handler to accept both single-tile and batched formats.

**Files:**
- Modify: `src/shared/TileOwnershipManager.luau` (lines 350–390: `captureTile` event firing, lines 406–414: `releaseTile` event firing)
- Modify: `src/playerscripts/TileVisualEffects.client.luau` (client event handler)

### REJECTED ALTERNATIVES
1. **Use UnreliableRemoteEvent for tile captures:** Tile ownership is gameplay-critical state — dropped packets would leave clients with wrong tile colors permanently.
2. **Debounce per-tile with longer window (1s):** Too much visual delay; players expect immediate feedback on capture.
3. **Only batch during war, not single captures:** Adds branching complexity for marginal gain — 0.1s batch window is imperceptible.

### SCALABILITY CHECK
- Batch fires once per 0.1s regardless of how many tiles were captured in that window.
- Worst case (country takeover): already batched by `performCountryTakeover`.
- Average case (combat captures): 1–5 tiles per batch = 1 event instead of 1–5.

### FAILURE SIMULATION
- Zero captures in window → no event fired (timer exits cleanly).
- Server shuts down during accumulation → pending captures lost, but tile state is already written server-side; clients reconnect to correct state.
- Client receives batch with destroyed tileParts → handler skips nil entries.

---

- [ ] **Step 1: Add batch accumulator to TileOwnershipManager**

Add near the top of the module, after existing local declarations:

```lua
-- Batch tile capture events to reduce network overhead
local pendingCaptureEvents = {} -- { {tilePart, playerName, countryName}, ... }
local batchTimerActive = false
local BATCH_WINDOW = 0.1 -- seconds to accumulate before firing

local function flushCaptureEvents()
	if #pendingCaptureEvents == 0 then
		batchTimerActive = false
		return
	end

	local TileCapturedEvent = ReplicatedStorage:FindFirstChild("TileCapturedEvent")
	if TileCapturedEvent then
		TileCapturedEvent:FireAllClients(pendingCaptureEvents)
	end

	table.clear(pendingCaptureEvents)
	batchTimerActive = false
end

local function queueCaptureEvent(tilePart, playerName, countryName)
	table.insert(pendingCaptureEvents, { tilePart, playerName, countryName })
	if not batchTimerActive then
		batchTimerActive = true
		task.delay(BATCH_WINDOW, flushCaptureEvents)
	end
end
```

- [ ] **Step 2: Replace ALL per-tile FireAllClients calls with queueCaptureEvent**

There are **6 per-tile** `TileCapturedEvent:FireAllClients` call sites in `TileOwnershipManager.luau`. Replace each with `queueCaptureEvent`:

| Line | Function | Current Call | Replacement |
|------|----------|-------------|-------------|
| 353 | `captureTile` (reclaim branch) | `FireAllClients(tilePart, player.Name, playerCountry)` | `queueCaptureEvent(tilePart, player.Name, playerCountry)` |
| 389 | `captureTile` (normal capture) | `FireAllClients(tilePart, player.Name, playerCountry)` | `queueCaptureEvent(tilePart, player.Name, playerCountry)` |
| 414 | `releaseTile` | `FireAllClients(tilePart, "", originalCountry)` | `queueCaptureEvent(tilePart, "", originalCountry)` |
| 459 | `reclaimTile` | `FireAllClients(tilePart, player.Name, playerCountry)` | `queueCaptureEvent(tilePart, player.Name, playerCountry)` |
| 490 | `releaseCountryOccupiedTiles` | `FireAllClients(tilePart, "", data.originalCountry)` | `queueCaptureEvent(tilePart, "", data.originalCountry)` |
| 553 | `releaseCountryOccupiedTiles` (inner loop) | `FireAllClients(tilePart, "", countryName)` | `queueCaptureEvent(tilePart, "", countryName)` |

**DO NOT touch line 755** — `performCountryTakeover` already sends its own batch format and should remain as-is.

- [ ] **Step 4: Update TileVisualEffects client handler to accept batched format**

In `TileVisualEffects.client.luau`, update the `TileCapturedEvent.OnClientEvent` handler to detect whether it received a batch (table of tables) or the legacy single-tile format:

```lua
TileCapturedEvent.OnClientEvent:Connect(function(tileDataOrPart, playerNameOrNil, countryNameOrNil)
	-- Detect batch format: array of {tilePart, playerName, countryName}
	if typeof(tileDataOrPart) == "table" then
		for _, entry in ipairs(tileDataOrPart) do
			local tilePart, playerName, countryName = entry[1], entry[2], entry[3]
			if tilePart and tilePart.Parent then
				applyTileVisual(tilePart, playerName, countryName)
			end
		end
	else
		-- Legacy single-tile format (also used by performCountryTakeover batch)
		if tileDataOrPart and tileDataOrPart.Parent then
			applyTileVisual(tileDataOrPart, playerNameOrNil, countryNameOrNil)
		end
	end
end)
```

Note: `performCountryTakeover` already sends its own batch format (array of Parts + playerName + country). You may need to reconcile these two batch formats or unify them. Check the existing client handler for `performCountryTakeover`'s batch format and ensure compatibility.

- [ ] **Step 5: Test in-game**

1. Have NPCs capture tiles in rapid succession (intense border combat).
2. Verify tile colors update on all clients with minimal delay (<0.1s perceptible).
3. Check network stats in Developer Console — event fire count should be reduced.
4. Verify `performCountryTakeover` still works correctly (it has its own batch path).

- [ ] **Step 6: Commit**

```bash
git add src/shared/TileOwnershipManager.luau src/playerscripts/TileVisualEffects.client.luau
git commit -m "perf: batch tile capture remote events with 0.1s accumulation window"
```

---

## Task 5: Incremental TileCursor Cache Eviction

**Problem:** `TileCursor.client.luau` uses an LRU cache with `CACHE_MAX_SIZE = 500`. When full, it evicts 250 entries in a single `RenderStepped` frame via `table.remove(cacheAccessOrder, 1)` in a loop — O(250²) due to array shifting. This causes a frame spike (stutter) on low-end devices.

**Solution:** Replace batch eviction with incremental eviction: remove 1–2 oldest entries per frame when the cache exceeds a soft limit. The cache never hits the hard limit, so no spike occurs.

**Files:**
- Modify: `src/playerscripts/TileCursor.client.luau` (lines 20–21: config, lines 66–92: `touchCacheEntry` + `evictOldestEntries`)

### REJECTED ALTERNATIVES
1. **Use a dictionary with timestamps instead of array:** Requires scanning all entries to find oldest — worse than incremental eviction.
2. **Reduce cache size to 100:** More frequent evictions; doesn't fix the batch-eviction spike.
3. **Use weak tables:** Roblox Parts have strong references from Workspace — weak table entries won't collect.

### SCALABILITY CHECK
- Eviction is O(1) per frame (remove 1 entry from array head + clear dict entry).
- Soft limit at 400, hard limit at 500 → 100-entry buffer absorbs rapid exploration.
- Worst case: player pans camera fast over 100 new tiles/sec → cache fills in 5s, eviction drains at 60/sec (one per frame), so net growth = 40/sec, still 2.5s before hard limit.

### FAILURE SIMULATION
- Cache grows past soft limit during lag spike → hard limit catch evicts 1 extra per frame until under soft limit.
- Part in cache is destroyed (StreamingEnabled) → cache entry points to nil Part, harmless (cache miss on next access triggers re-lookup).

---

- [ ] **Step 1: Update cache config constants**

Replace:
```lua
local CACHE_MAX_SIZE = 500
local CACHE_EVICT_COUNT = 250
```
with:
```lua
local CACHE_SOFT_LIMIT = 400   -- start evicting 1 per frame above this
local CACHE_HARD_LIMIT = 500   -- absolute max (safety net)
```

- [ ] **Step 2: Replace `evictOldestEntries` with incremental eviction**

Replace the existing `evictOldestEntries` function:

```lua
local function evictOldestEntries()
	-- Incremental: evict at most 2 entries per call (called once per RenderStepped)
	local evictCount = 0
	local maxEvict = 2

	while #cacheAccessOrder > CACHE_SOFT_LIMIT and evictCount < maxEvict do
		local oldPart = table.remove(cacheAccessOrder, 1)
		if oldPart then
			countryModelCache[oldPart] = nil
		end
		evictCount = evictCount + 1
	end
end
```

- [ ] **Step 3: Replace `touchCacheEntry` linear scan with dictionary-backed index**

The existing `touchCacheEntry` does a reverse linear scan to find and remove the part from `cacheAccessOrder` — O(N) per hover. Replace with a dictionary that tracks array position:

```lua
local cacheIndexMap = {} -- [part] = index in cacheAccessOrder

local function touchCacheEntry(part)
	local existingIdx = cacheIndexMap[part]
	if existingIdx then
		table.remove(cacheAccessOrder, existingIdx)
		-- Rebuild indices for shifted entries
		for i = existingIdx, #cacheAccessOrder do
			cacheIndexMap[cacheAccessOrder[i]] = i
		end
	end
	table.insert(cacheAccessOrder, part)
	cacheIndexMap[part] = #cacheAccessOrder
end
```

Alternatively, if the linear scan is acceptable (500 entries max, Luau tables are fast), keep the existing approach and just fix the eviction. The linear scan in `touchCacheEntry` is much less impactful than the batch eviction.

- [ ] **Step 4: Update cleanup to clear new data structures**

In the existing `cleanup` function, add:

```lua
table.clear(cacheIndexMap)
```

alongside the existing cache clearing.

- [ ] **Step 5: Test in-game**

1. Pan camera across the Europe map rapidly, hovering over many tiles.
2. Watch for frame rate drops — should be smooth (no 250-entry eviction spike).
3. Verify tile hover highlighting still works correctly.
4. Verify cache cleanup on player leave (no memory leak).

- [ ] **Step 6: Commit**

```bash
git add src/playerscripts/TileCursor.client.luau
git commit -m "perf: replace batch cache eviction with incremental per-frame eviction"
```

---

## Task 6: Adaptive NPC Processing LOD

**Problem:** All NPCs receive equal processing regardless of total NPC count. On low-end devices with 50+ NPCs, the cumulative cost of ground checks, combat ticks, and movement monitoring degrades frame rate.

**Solution:** Create an `NPCLODManager` that adapts processing frequency based on total active NPC count. When NPC count exceeds thresholds, non-critical processing (ground check frequency, combat tick rate, idle drift correction) is throttled.

**Files:**
- Create: `src/shared/NPCLODManager.luau`
- Modify: `src/shared/NPCMovementSystem.luau` (read LOD interval for ground checks)
- Modify: `src/shared/NPCCombatSystem.luau` (read LOD interval for combat ticks)

### REJECTED ALTERNATIVES
1. **Distance-based LOD from camera:** This is a server-side game — NPCs process on server, no camera concept.
2. **Hard NPC cap:** Degrades gameplay (players can't buy more NPCs). Throttling is better than blocking.
3. **Skip processing for "idle" NPCs entirely:** Idle NPCs can still fall off tiles or drift; must maintain ground checks.

### SCALABILITY CHECK
- LOD tiers: 0–30 NPCs (full rate), 30–60 (reduced ground checks), 60–100 (reduced combat rate + ground checks), 100+ (aggressive throttle).
- Tier transitions are smooth — no sudden behavior changes.
- LOD only affects processing *frequency*, not correctness.

### FAILURE SIMULATION
- NPC count fluctuates around tier boundary → hysteresis prevents rapid tier switching (must stay above threshold for 2s).
- All NPCs in combat at highest LOD tier → combat rate drops from 10/sec to 5/sec. Damage output halves but is consistent for all NPCs.
- NPC falls off tile during reduced ground check → still detected within 0.5s (worst case at highest tier), recovery still works.

---

- [ ] **Step 1: Create NPCLODManager module**

Create `src/shared/NPCLODManager.luau`:

```lua
-- NPCLODManager: Adapts NPC processing frequency based on active NPC count.
-- Other systems read LOD intervals instead of using hardcoded values.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local NPCLODManager = {}

-- LOD tiers (NPC count thresholds)
local TIERS = {
	{ maxNPCs = 30,  groundCheckInterval = 0.1,  combatTickInterval = 0.1,  label = "Full" },
	{ maxNPCs = 60,  groundCheckInterval = 0.2,  combatTickInterval = 0.1,  label = "Medium" },
	{ maxNPCs = 100, groundCheckInterval = 0.3,  combatTickInterval = 0.15, label = "Reduced" },
	{ maxNPCs = math.huge, groundCheckInterval = 0.5, combatTickInterval = 0.2, label = "Minimal" },
}

local currentTier = TIERS[1]
local tierChangeStartTime = nil -- os.clock() when we first detected a different target tier
local HYSTERESIS_SECONDS = 2 -- must stay above threshold for this long before tier change
local pendingTargetTier = nil

local function updateTier()
	local npcCount = #CollectionService:GetTagged("RegisteredNPC")

	local targetTier = TIERS[1]
	for _, tier in ipairs(TIERS) do
		if npcCount <= tier.maxNPCs then
			targetTier = tier
			break
		end
	end

	if targetTier ~= currentTier then
		if targetTier ~= pendingTargetTier then
			-- New target tier detected — start hysteresis timer
			pendingTargetTier = targetTier
			tierChangeStartTime = os.clock()
		elseif os.clock() - tierChangeStartTime >= HYSTERESIS_SECONDS then
			-- Held long enough — apply tier change
			currentTier = targetTier
			pendingTargetTier = nil
			tierChangeStartTime = nil
		end
	else
		-- Back to current tier — cancel pending change
		pendingTargetTier = nil
		tierChangeStartTime = nil
	end
end

-- Public API
function NPCLODManager.getGroundCheckInterval()
	return currentTier.groundCheckInterval
end

function NPCLODManager.getCombatTickInterval()
	return currentTier.combatTickInterval
end

function NPCLODManager.getCurrentTierLabel()
	return currentTier.label
end

-- Single Heartbeat to update tier (very lightweight — 1 GetTagged call per second)
local accumulator = 0
RunService.Heartbeat:Connect(function(dt)
	accumulator = accumulator + dt
	if accumulator < 1 then return end -- check once per second
	accumulator = 0
	updateTier()
end)

return NPCLODManager
```

- [ ] **Step 2: Integrate LOD into NPCMovementSystem ground check**

In the consolidated Heartbeat loop from Task 2, replace the hardcoded `GROUND_CHECK_INTERVAL` comparison:

```lua
local NPCLODManager = require(game.ServerScriptService:WaitForChild("NPCLODManager", 10))

-- Inside onMovementHeartbeat, replace:
--   if reg.groundAccum >= GROUND_CHECK_INTERVAL then
-- with:
if reg.groundAccum >= NPCLODManager.getGroundCheckInterval() then
```

- [ ] **Step 3: Integrate LOD into NPCCombatSystem combat tick**

In the consolidated combat tick from Task 3, replace the hardcoded `LOOP_WAIT` comparison:

```lua
local NPCLODManager = require(game.ServerScriptService:WaitForChild("NPCLODManager", 10))

-- Inside onCombatTick, replace:
--   if combatAccumulator < LOOP_WAIT then return end
-- with:
if combatAccumulator < NPCLODManager.getCombatTickInterval() then return end
```

- [ ] **Step 4: Test with varying NPC counts**

1. Start with 10 NPCs → verify "Full" tier, normal responsiveness.
2. Spawn 50 NPCs → verify tier transitions to "Medium" after 2s hysteresis.
3. Spawn 80 NPCs → verify "Reduced" tier, combat is slightly slower but functional.
4. Spawn 120 NPCs → verify "Minimal" tier, game still runs (lower fidelity but stable).
5. Remove NPCs back to 20 → verify tier returns to "Full."

- [ ] **Step 5: Commit**

```bash
git add src/shared/NPCLODManager.luau src/shared/NPCMovementSystem.luau src/shared/NPCCombatSystem.luau
git commit -m "perf: add adaptive NPC LOD system that throttles processing at high NPC counts"
```

---

## Execution Order & Dependencies

```
Task 1 (Beam Pool) ──────────────────┐
Task 5 (Cache Eviction) ─────────────┤── Independent, can run in parallel
Task 4 (Batch Events) ───────────────┘
Task 2 (Heartbeat Consolidation) ────┐
Task 3 (Combat Loop Consolidation) ──┤── Independent of each other, but both modify NPCMovementSystem/NPCCombatSystem
                                      └── Task 6 depends on Tasks 2 & 3 being complete
Task 6 (NPC LOD) ────────────────────── Must run after Tasks 2 & 3
```

**Recommended execution order:** Tasks 1, 4, 5 in parallel → Tasks 2, 3 in parallel → Task 6 last.

---

## Expected Performance Impact Summary

| Optimization | Metric | Before | After | Device Impact |
|-------------|--------|--------|-------|---------------|
| Beam pooling | Part alloc/sec | N (one per NPC shot) | 0 (after warmup) | Reduces GC pauses |
| Heartbeat consolidation | RBXScriptConnections | 3N | 1 | Reduces per-frame dispatch overhead |
| Combat loop consolidation | Active coroutines | N | 1 | Reduces scheduler overhead |
| Batch tile events | Remote fires/sec | N (per tile) | 1 per 0.1s window | Reduces network bandwidth |
| Cache eviction | Frame spike (ms) | ~5–15ms every ~8s | <0.1ms per frame | Eliminates stutter |
| NPC LOD | Processing cost at 100 NPCs | Full rate | 50–70% of full rate | Maintains playability |

Where N = active NPC count.
