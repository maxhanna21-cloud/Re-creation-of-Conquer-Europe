Implementation Plan: NPC Movement Routing Fix

🔍 Root Cause Analysis

Based on the server logs, we can observe the exact moment the routing fails:

Adjacency Detected: The system correctly identifies that Республика Карелия and (Материк) Ленинградская область are adjacent.

Edge Proof Found: [NPCMovement:Waypoints] Edge check: ... pointA=(-103.0,4.6,343.0), pointB=(-103.0,4.6,343.0) shows that the TileAdjacencyManager successfully provided the exact physical bridge/strait coordinates where the two tiles connect.

The Failure (Waypoint Pruning/Omission): Immediately after finding the edge, the log states: Built 2 enriched waypoints: [1] tile at (-84.3... [2] tile at (-94.3....

The system completely dropped the edge points. It is only trying to walk in a straight, direct line from Center A to Center B.

The Consequence: Because the map geometry between those two specific centers contains a gap (water or an irregular concave boundary), the straight line goes off the edge. The NPC falls, triggering the GroundCheck teleport recovery (falls: 1), and gets stuck in an infinite loop of trying to walk that same straight line.

Even if the edge points were included, relying on a straight line (Humanoid:MoveTo) from a tile's center to its edge will fail if the tile is L-shaped or crescent-shaped.

⚠️ CODE REVIEW FINDINGS

After reviewing the current state of NPCMovementSystem.luau (1,982 lines), **Steps 1-4 below have already been implemented** in prior fixes (v6 through v18). Specifically:

- **Step 1 (Edge Point Injection):** Already implemented at lines 664-879 in `buildEnrichedWaypoints()`. Edge points from `getAdjacencyProof()` are injected for both small-gap (<3 stud) and large-gap crossings. No pruning/smoothing removes them.

- **Step 2 (Micro-Pathfinding):** Already implemented. The `computeWalkablePath()` function (line 526) uses `PathfindingService:ComputeAsync()` and is called at lines 724, 757, 780, and 891 to pathfind between waypoints (center-to-edge, edge-to-edge, and edge-to-center). A cell-based BFS fallback via `TileAdjacencyManager.findCellPath()` also exists (lines 797, 908) for when PathfindingService fails on narrow tiles.

- **Step 3 (Enhanced Teleport Recovery):** Already implemented. `teleportToSafeTile()` (line 957) tracks `fallRecoveries` (line 1003), and the system aborts movement after `MAX_FALL_RECOVERIES` consecutive falls (line 1009) rather than looping infinitely.

- **Step 4 (Agent Parameters):** Already implemented at lines 527-531 with `AgentRadius = 2`, `AgentHeight = 5`, `AgentCanJump = false`, `WaypointSpacing = 4`. These match the recommended values except `AgentCanJump` is `false` (likely intentional to prevent NPCs from jumping off edges).

🔎 Remaining Bug: Why Are Edge Points Still Dropped?

If the log shows only 2 tile-center waypoints despite the edge proof being found, the issue is likely one of these scenarios:

1. **The edge distance is at or below the 0.1-stud epsilon threshold** (line 674: `edgeDist > 0.1`). When `pointA` and `pointB` are identical (both at `-103.0, 4.6, 343.0` per the log), `edgeDist = 0`, which means `isGapCrossing = false` and no edge points are injected. The system treats them as touching tiles and falls through to a center-to-center path.

2. **The adjacency is real but the crossing proof coordinates are degenerate** — `pointA == pointB` means the edge-finding algorithm collapsed the two bridge endpoints to a single point, likely because the tiles share a vertex or extremely narrow contact.

🛠️ Targeted Fix Plan

Since the core infrastructure is already in place, only a narrow fix is needed:

**Step 1: Handle Zero-Distance Edge Crossings (Lines 674-679)**

Location: `buildEnrichedWaypoints()`, around line 674.

Problem: When `edgeDist <= 0.1` (touching tiles or degenerate edge proof), no edge waypoints are injected. The NPC walks center-to-center in a straight line, which can cross water on irregularly shaped tiles.

Action: When tiles are adjacent but not gap-crossing (`edgeDist <= 0.1`), still inject edge point(s) as intermediate waypoints and use `computeWalkablePath()` to pathfind from the previous position to the edge point, then from the edge point to the next tile center. This ensures the NPC follows walkable geometry even on touching tiles with concave shapes.

```lua
-- After line 679, add handling for non-gap adjacent tiles:
elseif pointA and pointB then
    -- Touching tiles (edgeDist <= 0.1): still inject edge waypoint(s)
    -- to avoid straight center-to-center lines crossing voids on curved tiles.
    local prevPos = waypoints[#waypoints].position
    local edgeMidpoint = (pointA + pointB) / 2

    -- Pathfind from current position to the shared edge
    local pfToEdge = computeWalkablePath(prevPos, edgeMidpoint)
    if #pfToEdge > 0 then
        for _, pfPos in ipairs(pfToEdge) do
            table.insert(waypoints, {
                type = "pathfind",
                position = pfPos,
                tile = prevTile
            })
        end
    end

    -- Insert the edge midpoint as a waypoint
    table.insert(waypoints, {
        type = "edge",
        position = edgeMidpoint,
        tile = prevTile
    })
end
```

**Step 2: Validate Edge Proof Quality in TileAdjacencyManager**

Location: `TileAdjacencyManager.luau`, inside `getAdjacencyProof()`.

Problem: When `pointA == pointB`, the edge proof is degenerate (zero-length bridge). This can happen when tiles share only a vertex or an extremely narrow contact.

Action: Add a warning log when the returned edge proof has `pointA == pointB`, and attempt to find a better crossing point by sampling additional candidates along the shared boundary. If no better proof exists, return the degenerate proof but flag it so the movement system knows to rely more heavily on PathfindingService for that crossing.

**Step 3: Add Fallback PathfindingService Route for Non-Gap Crossings**

Location: `monitorMovement()`, around line 1324.

Problem: Even after injecting edge waypoints, `Humanoid:MoveTo()` between consecutive waypoints can still fail if the straight-line segment crosses water. The gap-crossing teleport logic (lines 1277-1322) only activates when tiles differ between consecutive edge waypoints.

Action: Add stuck detection specifically for non-gap movements. If the NPC has not made progress toward its current waypoint for more than 3 seconds, run `computeWalkablePath()` from the NPC's current position to the target waypoint, and replace the remaining movement with those PathfindingService waypoints. This acts as a runtime safety net.
