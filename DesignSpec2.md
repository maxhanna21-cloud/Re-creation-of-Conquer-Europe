# Design Spec: Precomputed Tile Adjacency Pipeline

## 1. Goal

Move tile adjacency calculation out of live server runtime and into a pre-game / pre-publish generation step.

The live Roblox server should no longer rasterize tiles, raycast tile borders, scan all tile pairs, classify straits, or calculate safe centers during gameplay startup.

At runtime, `TileAdjacencyManager` should only:

- scan `Workspace.EuropeMap`'s descendants for tile `BasePart`s (which are nested inside country `Model`s),
- resolve stable `TileId` values to live `BasePart` instances,
- load precomputed adjacency data from a generated ModuleScript,
- expose the same public APIs currently used by movement, targeting, combat, and ownership systems.

## 2. Current Problem

The current `src/shared/TileAdjacencyManager.lua` performs expensive work when the module is required.

At the bottom of the module it currently runs:

```lua
scanAllTiles()
rasterizeAllTiles()
calculateAdjacenciesFromFootprints()
calculateExtendedAdjacencies()
applyExplicitStraitConnections()
calculateSafeCenters()
````

The expensive parts are:

* rasterizing every tile using raycasts,
* building raster cell maps,
* checking candidate pairs,
* running evidence-first walkability / strait classification,
* calculating safe centers,
* generating adjacency proof data.

This work should be performed once during development/build time, not every live server session.

## 3. Desired Architecture

Introduce a generated static data module:

```text
src/shared/generated/PrecomputedTileAdjacencyData.lua
```

This module should contain serialized adjacency information keyed by stable `TileId`.

Runtime `TileAdjacencyManager` should become a loader/query module.

The expensive generation logic should move into a separate Studio-only generator module or command script.

Recommended files:

```text
src/shared/TileAdjacencyManager.lua
src/shared/generated/PrecomputedTileAdjacencyData.lua
src/tools/GenerateTileAdjacency.server.lua
src/tools/TileAdjacencyGenerator.lua
```

The exact tool location can change, but generation code must not run in production server startup.

## 4. Stable Tile Identity

Use the existing `TileId` attribute as the authoritative tile identity.

Every tile `BasePart` under `Workspace.EuropeMap` (nested within country `Model`s) must have a unique, stable `TileId`.

Do not rely on scan order.

Do not rely on rounded position keys as primary identity.

Do not serialize `Instance` references.

Do not serialize `Vector3` objects directly if the generated module must be plain Luau source.

Represent vectors as numeric arrays:

```lua
{ x, y, z }
```

Use this format consistently throughout all generated data.

## 5. Generated Data Shape

The generated module should return a plain table.

Recommended shape:

```lua
return {
    version = 1,

    config = {
        rasterCellSize = 2,
        maxRasterAdjacencyDistance = 6,
        extendedAdjacencyThreshold = 3,
        narrowStraitThreshold = 8,
        maxStraitWaterGap = 5,
        adjacencyAllowDiagonal = false,
    },

    generatedAtUnix = 1234567890, -- informational only, not part of fingerprint comparison

    mapFingerprint = {
        tileCount = 1234,
        geometryHash = "sha256:abc123...", -- deterministic hash of tile IDs, CFrames, sizes
        generatorVersion = "precomputed-adjacency-v1",
    },

    tiles = {
        ["Workspace.EuropeMap.France.Normandie"] = {
            name = "Normandie",
            country = "France",
            safeCenter = { 10, 3, 20 },
        },
    },

    adjacency = {
        ["Workspace.EuropeMap.France.Normandie"] = {
            "Workspace.EuropeMap.France.Bretagne",
            "Workspace.EuropeMap.France.Ile-de-France",
        },
    },

    proofs = {
        ["Workspace.EuropeMap.France.Normandie"] = {
            ["Workspace.EuropeMap.France.Bretagne"] = {
                mode = "raster",
                pointA = { 1, 2, 3 },
                pointB = { 4, 2, 5 },
                distance = 2.25,
            },
        },
    },

    -- footprints are NOT serialized in this module.
    -- findCellPath() uses a runtime micro-rasterizer; see Section 6.
}
```

## 6. Data That Must Be Precomputed

The generator should precompute and serialize:

* tile metadata by `TileId`,
* bidirectional adjacency lists,
* adjacency proof data,
* safe centers.

Raster footprints are **not** serialized. See the footprint note below.

Adjacency proof data must preserve the current behavior of:

```lua
TileAdjacencyManager.getAdjacencyProof(tileA, tileB)
```

Safe centers must preserve the current behavior of:

```lua
TileAdjacencyManager.getSafeCenter(tilePart)
```

**Footprint note:** With `RASTER_CELL_SIZE = 2`, a single large tile can produce thousands of `"cx,cz"` cell keys. Serializing all 1200+ tiles' footprints into the generated module would likely exceed Roblox's script size limits and cause severe memory spikes on require. Instead, `findCellPath()` must call a **runtime micro-rasterizer**: a function that rasterizes only the single requested tile on demand, caches the result per-tile, and does not run at startup. `NPCMovementSystem` calls `findCellPath()` three times per movement sequence, so this keeps the call fast after the first cache hit while keeping startup instant.

## 7. Generator Responsibilities

If a tile `BasePart` lacks a `TileId` attribute, the generator must assign one (using `part:GetFullName()` or a deterministic scheme), write it back to the `BasePart` as an attribute, and save the place file. This guarantees TileId stability across hierarchy moves — once assigned, the ID persists even if the part is reparented.

The generator should reuse the existing expensive logic from `TileAdjacencyManager` as much as possible.

It should perform:

```lua
scanAllTiles()
rasterizeAllTiles()
calculateAdjacenciesFromFootprints()
calculateExtendedAdjacencies()
applyExplicitStraitConnections()
calculateSafeCenters()
```

Then it should export the resulting runtime tables into generated Luau source.

The generated file must be deterministic enough for source control review.

Sort tile IDs alphabetically before writing output.

Sort each tile’s neighbor list alphabetically before writing output.

Sort proof keys alphabetically.

## 8. Runtime Loader Responsibilities

At runtime, `TileAdjacencyManager` should:

* scan all live tile descendant parts under `Workspace.EuropeMap` (filtering for `BasePart`s to ignore non-tile instances like `IntValue`s),
* ensure every tile has a unique `TileId`,
* build `TileIdToPart`,
* build `PositionToTiles` only for legacy fallback APIs,
* load `PrecomputedTileAdjacencyData`,
* convert serialized tile IDs into live `BasePart` references,
* rebuild `AdjacentTiles[tilePart] = { neighborPart, ... }`,
* rebuild `AdjacencyProof[tileA][tileB]`,
* rebuild `TileSafeCenter[tilePart]`,
* do NOT rebuild `TileFootprint` from serialized data — footprints are not in the generated module; `findCellPath()` uses a runtime micro-rasterizer (see Section 6).

Runtime must not call:

```lua
rasterizeAllTiles()
calculateAdjacenciesFromFootprints()
calculateExtendedAdjacencies()
applyExplicitStraitConnections()
calculateSafeCenters()
```

except inside an explicit Studio-only diagnostic or regeneration mode.

## 9. Public API Compatibility

The following APIs should keep their current signatures:

```lua
getTileAtPosition(position)
getTileFromKey(tileKey)
getTileFromId(tileId)
getTileId(tilePart)
getTileFromKeyWithFallback(tileKey)
getAdjacentTiles(tilePart)
areTilesAdjacent(tilePartA, tilePartB)
getTileCountry(tilePart)
getEffectiveOwner(tilePart)
getAdjacentEnemyTiles(tilePart)
canNPCsInteract(npcA, npcB)
arePositionsAdjacent(positionA, positionB)
areTileKeysAdjacent(tileKeyA, tileKeyB)
getTileUnderPosition(position)
getSafeCenter(tilePart)
getAdjacencyProof(tileA, tileB)
findCellPath(tilePart, startPos, endPos)
getCountryTileParts(countryName)
getStats()
```

Any expensive/debug-only APIs should be moved behind a development flag:

```lua
diagnoseAdjacency(tileA, tileB)
debugAdjacency(tileA, tileB)
tryRepairAdjacencyPair(tileA, tileB)
recalculate()
visualizeFootprint(tilePart, color3)
clearFootprintVisuals()
```

## 10. Production Behavior

In production, `TileAdjacencyManager.recalculate()` should not regenerate adjacency data.

Recommended behavior:

```lua
function TileAdjacencyManager.recalculate()
    error("Runtime adjacency recalculation is disabled. Run the Studio generator instead.")
end
```

Alternatively, allow recalculation only when:

```lua
RunService:IsStudio()
```

and a local development flag is enabled.

## 11. Handling Explicit Strait Connections

The existing `STRAIT_CONNECTIONS` table should move to generator-owned configuration.

Explicit straits should be applied during generation.

The generated runtime data should already include those edges.

Runtime should not need to re-apply `STRAIT_CONNECTIONS`.

The generated proof for explicit straits should preserve:

```lua
mode = "strait"
```

and should include `pointA`, `pointB`, and `distance`.

## 12. Runtime Validation Policy

Current movement code revalidates raster proofs with `isPathWalkable()` during movement.

For best performance, the implementation planner should consider trusting precomputed proofs at runtime.

Recommended first-safe version:

* keep `isPathWalkable()` available,
* avoid using it during startup,
* optionally keep movement-time validation for non-strait direct moves.

Recommended optimized version:

* trust generated proofs,
* do not run live proof repair,
* stub `tryRepairAdjacencyPair()` in production so it returns `false` — never throw or remove it; `NPCTargetingHandler` calls it and expects a boolean result,
* treat missing proof as a generation error.

## 13. Missing or Stale Data Handling

Runtime loader must validate the generated data against the live map.

Validation checks:

* every live tile has a `TileId`,
* every live `TileId` is unique,
* every generated tile ID exists in the live map,
* every adjacency neighbor ID exists,
* every proof pair references valid tile IDs,
* every adjacent pair has proof data unless intentionally exempt,
* generated tile count equals live tile count.

If validation fails in production, fail loudly with a clear error.

Do not silently regenerate.

Do not silently ignore missing adjacency data.

In Studio, if the fingerprint mismatches or tiles are missing from the precomputed data, the runtime loader must:

1. Warn clearly in the output window: `"PrecomputedTileAdjacencyData is stale — re-running generator."`
2. Automatically invoke the generation pipeline in-memory so the developer can test immediately without manually running the generator tool.
3. Never pass `nil` adjacency data silently to downstream systems — missing adjacency produces unpredictable errors far from the source.

Silent fallback to the old runtime rasterization path is not acceptable: it hides staleness and risks shipping stale data to production.

## 14. Map Fingerprint

The generator should produce a lightweight map fingerprint.

Recommended fingerprint inputs:

* tile count,
* sorted list of tile IDs,
* each tile’s name,
* country model name,
* position,
* size,
* orientation or CFrame components.

The fingerprint must be a **deterministic hash of geometry only**. Never include `generatedAtUnix` or any timestamp in the hash inputs. A timestamp cannot be recomputed at runtime (it would use the current time and always mismatch), and embedding it in the generated source file guarantees spurious Git diffs on every regeneration even when geometry is unchanged. `generatedAtUnix` is stored in the module as informational metadata only (see Section 5) and must be excluded from the runtime comparison.

Runtime should recompute the fingerprint from the live map and compare it to `mapFingerprint.geometryHash` in the generated module.

If the map changed after generation, runtime should report:

```text
PrecomputedTileAdjacencyData is stale. Run GenerateTileAdjacency before publishing.
```

## 15. Serialization Format Requirements

The generated Luau file should avoid Roblox-only userdata in static table literals.

Use plain strings, numbers, booleans, and tables.

At runtime, reconstruct vectors using array indexing (the mandated format from Section 4):

```lua
local function toVector3(v)
	return Vector3.new(v[1], v[2], v[3])
end
```

Do not use named-key reconstruction (`v.x, v.y, v.z`). All vector data in the generated file uses positional arrays.

## 16. Generator Output Requirements

The generator should print a summary after successful generation:

```text
Generated PrecomputedTileAdjacencyData
Tiles: N
Connections: M
Average degree: X
Strait connections: S
Safe centers: N
Footprints serialized: no (micro-rasterizer used at runtime)
Output: src/shared/generated/PrecomputedTileAdjacencyData.lua
```

It should also print validation failures, including:

* duplicate tile IDs,
* missing explicit strait tile names,
* tiles with zero footprint cells,
* adjacency pairs without proof,
* one-way adjacency mismatches.

## 17. Integration With Rojo Project

Update `default.project.json` to include:

```json
"PrecomputedTileAdjacencyData": {
  "$path": "src/shared/generated/PrecomputedTileAdjacencyData.lua"
}
```

The actual placement should ensure `TileAdjacencyManager` can require it from `ServerScriptService`.

Example runtime require:

```lua
local PrecomputedData = require(game.ServerScriptService:WaitForChild("PrecomputedTileAdjacencyData"))
```

If the generated module is nested in a folder, update the require path accordingly.

## 18. Migration Steps

Step 1: Extract existing generation logic into reusable private functions or a generator module.

Step 2: Add a serializer that writes static Luau data.

Step 3: Generate `PrecomputedTileAdjacencyData.lua` from the current map.

Step 4: Refactor `TileAdjacencyManager` startup to load precomputed data instead of calculating it.

Step 5: Keep the old calculation path available only in Studio regeneration mode.

Step 6: Validate all existing public API callers still work.

Step 7: Profile live server startup before and after migration.

## 19. Acceptance Criteria

Runtime server startup does not rasterize tiles.

Runtime server startup does not calculate extended adjacency pairs.

Runtime server startup does not apply explicit straits dynamically.

Runtime server startup does not calculate safe centers dynamically.

`TileAdjacencyManager.getStats()` returns the same or intentionally reviewed connection counts as before.

NPC direct movement still works.

NPC multi-tile BFS still works.

Strait movement still works.

`getAdjacencyProof()` returns proof data for every adjacent pair.

`getSafeCenter()` returns a valid position for every tile.

No production code path calls `TileAdjacencyManager.recalculate()`.

## 20. Non-Goals

Do not redesign the entire NPC movement system in this change.

Do not change tile ownership logic.

Do not change diplomacy rules.

Do not change `TileKeyUtils` behavior except where needed for compatibility.

Do not introduce runtime DataStore dependency for adjacency data.

Do not fetch adjacency data over the network.

## 21. Risks

If `TileId` values are based on `GetFullName()`, renaming or moving map parts will stale the generated data.

If the runtime micro-rasterizer for `findCellPath()` is removed without a replacement, cell-level pathfinding will break.

If runtime movement continues to revalidate proofs with raycasts, some performance cost will remain.

If the live map differs from the generated map, adjacency behavior may be wrong unless fingerprint validation blocks startup.

## 22. Recommended Final State

The final system should treat adjacency as build artifact data.

The expensive geometry pipeline should be a developer tool.

The live server should only hydrate precomputed adjacency data into fast lookup tables.

Runtime adjacency queries should be O(1) or near-O(1).

Any map geometry change should require rerunning the generator before publishing.

```
```