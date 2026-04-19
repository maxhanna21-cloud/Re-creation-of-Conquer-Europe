# Roblox Studio ↔ Local Files Bidirectional Sync

This setup allows you to sync changes between Roblox Studio and your local `.luau` files automatically.

## Quick Start

### 🔄 Continuous Sync (Recommended)
Run the continuous sync that automatically detects changes:
```bash
./start_sync.command
```
This will start a background process that:
- Monitors Roblox Studio for changes every 10 seconds
- Automatically syncs modified scripts to your local files
- Logs all activity to `studio_sync.log`
- Only syncs when actual changes are detected (smart mode)

### Manual Sync
1. Make changes in Roblox Studio
2. Run the sync script:
   ```bash
   ./sync_from_studio.command
   ```

### What's Already Set Up
- ✅ Roblox Studio MCP connection is active
- ✅ Script mappings are configured based on `default.project.json`
- ✅ Basic sync script is ready to use
- ✅ File structure matches Studio hierarchy

## How It Works

### Studio → Local Sync
The system reads scripts from your Roblox Studio project and writes them to your local `src/` directory:

```
Roblox Studio                    Local Files
┌─────────────────┐              ┌─────────────────┐
│ ServerScriptService │          │ src/shared/     │
│  ├ DiplomacyManager │ ──► │  ├ DiplomacyManager.luau │
│  ├ NPCCombatSystem │ ──► │  ├ NPCCombatSystem.luau │
│  └ ...           │          │  └ ...           │
└─────────────────┘              └─────────────────┘
```

### Script Mappings
The sync follows these mappings (defined in `default.project.json`):

**Shared Modules** (`src/shared/`):
- `DiplomacyManager.luau`
- `NPCCombatSystem.luau`
- `NPCMovementSystem.luau`
- `ServerState.luau`
- `TileAdjacencyManager.luau`
- `TileKeyUtils.luau`
- `TileManager.luau`
- `TileOwnershipManager.luau`
- `UnitManager.luau`

**Server Scripts** (`src/server/`):
- `Auto-Fix.server.luau`
- `CollisionSetup.server.luau`
- `CountryManager.server.luau`
- `Diagnostics.server.luau`
- `DiplomacyServer.server.luau`
- `Leaderstats.server.luau`
- `CountryNPCRegistry.luau`
- `NPCPurchaseHandler.server.luau`
- `NPCSpawner.luau`
- `NPCTargetingHandler.server.luau`

**Player Scripts** (`src/playerscripts/`):
- `NPCVisualsHandler.luau`
- `TileCursor.luau`
- `TileClickHandler.luau`
- `TileVisualEffects.luau`

**Client Scripts** (`src/client/`):
- `BuyNPCGui.client.luau`
- `CountrySelectionScreen.client.luau`
- `DiplomacyGui.client.luau`
- `NotificationGui.client.luau`

## Usage Examples

### Continuous Sync (Recommended)
```bash
# Start automatic sync that runs in background
./start_sync.command

# Or choose specific mode:
./continuous_sync.command     # Simple timer-based sync
./continuous_sync.py          # Smart change detection sync
```

### Manual Sync
```bash
# Sync all scripts from Studio to local
./sync_from_studio.command
```

### Checking What Changed
```bash
# See which files were recently updated
find src -name "*.luau" -newer sync_from_studio.command

# View sync logs
tail -f studio_sync.log
```

## Future Enhancements

### ✅ Automatic Sync (Completed)
- ✅ File watcher that detects Studio changes automatically
- ✅ Continuous sync that runs in background
- ✅ Smart change detection to avoid unnecessary syncs
- 🔄 Real-time sync as you edit in Studio (10-second intervals)
- ⏳ Conflict resolution for simultaneous changes

### Local → Studio Sync (Planned)
- Sync local changes back to Studio
- Two-way synchronization
- Automatic backup before sync

## Troubleshooting

### Studio Not Connected
Make sure Roblox Studio is running and the MCP connection is active:
1. Open Roblox Studio
2. Load your project
3. The MCP connection should establish automatically

### Files Not Syncing
1. Check that the script path exists in Studio
2. Verify the local file path is correct
3. Make sure you have write permissions to the `src/` directory

### Manual Override
If automatic sync isn't working, you can always:
1. Copy-paste scripts manually from Studio to local files
2. Use the existing `update_split.command` to rebuild the combined files

## Files Created

- `sync_from_studio.command` - Manual sync script
- `start_sync.command` - Launcher for continuous sync (recommended)
- `continuous_sync.command` - Simple timer-based continuous sync
- `continuous_sync.py` - Smart change detection continuous sync
- `studio_to_local_sync.py` - Python sync implementation
- `watch_studio_changes.sh` - File watcher (legacy)
- `STUDIO_SYNC_README.md` - This documentation

## Integration with Existing Tools

This sync system works alongside your existing tools:
- `update_split.command` - Still works for creating `largescripts.txt` and `restofcodebase.txt`
- `default.project.json` - Used as the source of truth for script mappings
- Your existing `.luau` files - Remain the primary local development files

## Best Practices

1. **Save frequently in Studio** - Changes are only synced when you run the sync script
2. **Test after sync** - Make sure your local files reflect the Studio changes
3. **Backup before major changes** - Keep a copy of important scripts
4. **Use version control** - Commit your local files to git regularly

## Need Help?

If you encounter issues:
1. Check that Roblox Studio is running
2. Verify the MCP connection is active
3. Run the sync script manually to see error messages
4. Check file permissions in your project directory
