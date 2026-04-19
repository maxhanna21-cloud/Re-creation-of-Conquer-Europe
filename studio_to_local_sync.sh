#!/bin/bash
# Bidirectional sync: Roblox Studio -> Local files
# This script uses Roblox Studio MCP to read scripts and write them to local .luau files

cd "$(dirname "$0")"
SRC_DIR="src"

echo "🔄 Starting Studio to local sync..."

# Function to read a script from Studio using MCP and write to local file
sync_script() {
    local instance_path="$1"
    local local_path="$2"
    
    echo "  📝 Syncing $instance_path -> $local_path"
    
    # Create directory if it doesn't exist
    local dir=$(dirname "$local_path")
    mkdir -p "$dir"
    
    # Use a temporary Python script to call MCP functions
    python3 -c "
import subprocess
import json
import sys

# Call MCP script_read function
result = subprocess.run([
    'mcp', 'call', 'Roblox_Studio', 'script_read',
    json.dumps({'target_file': '$instance_path'})
], capture_output=True, text=True)

if result.returncode == 0:
    try:
        data = json.loads(result.stdout)
        if 'content' in data:
            with open('$local_path', 'w') as f:
                f.write(data['content'])
            print(f'    ✅ Synced {len(data[\"content\"].splitlines())} lines')
            sys.exit(0)
    except:
        pass

print(f'    ❌ Failed to read $instance_path')
sys.exit(1)
"
}

# Read all scripts from Studio based on default.project.json mapping
echo "📚 Reading scripts from Studio..."

# ServerScriptService scripts
sync_script "game.ServerScriptService.DiplomacyManager" "$SRC_DIR/shared/DiplomacyManager.luau"
sync_script "game.ServerScriptService.NPCCombatSystem" "$SRC_DIR/shared/NPCCombatSystem.luau"
sync_script "game.ServerScriptService.NPCMovementSystem" "$SRC_DIR/shared/NPCMovementSystem.luau"
sync_script "game.ServerScriptService.ServerState" "$SRC_DIR/shared/ServerState.luau"
sync_script "game.ServerScriptService.TileAdjacencyManager" "$SRC_DIR/shared/TileAdjacencyManager.luau"
sync_script "game.ServerScriptService.TileKeyUtils" "$SRC_DIR/shared/TileKeyUtils.luau"
sync_script "game.ServerScriptService.TileManager" "$SRC_DIR/shared/TileManager.luau"
sync_script "game.ServerScriptService.TileOwnershipManager" "$SRC_DIR/shared/TileOwnershipManager.luau"
sync_script "game.ServerScriptService.UnitManager" "$SRC_DIR/shared/UnitManager.luau"

sync_script "game.ServerScriptService.Auto-Fix" "$SRC_DIR/server/Auto-Fix.server.luau"
sync_script "game.ServerScriptService.CollisionSetup" "$SRC_DIR/server/CollisionSetup.server.luau"
sync_script "game.ServerScriptService.CountryManager" "$SRC_DIR/server/CountryManager.server.luau"
sync_script "game.ServerScriptService.Diagnostics" "$SRC_DIR/server/Diagnostics.server.luau"
sync_script "game.ServerScriptService.DiplomacyServer" "$SRC_DIR/server/DiplomacyServer.server.luau"
sync_script "game.ServerScriptService.Leaderstats" "$SRC_DIR/server/Leaderstats.server.luau"
sync_script "game.ServerScriptService.CountryNPCRegistry" "$SRC_DIR/server/CountryNPCRegistry.luau"
sync_script "game.ServerScriptService.NPCPurchaseHandler" "$SRC_DIR/server/NPCPurchaseHandler.server.luau"
sync_script "game.ServerScriptService.NPCSpawner" "$SRC_DIR/server/NPCSpawner.luau"
sync_script "game.ServerScriptService.NPCTargetingHandler" "$SRC_DIR/server/NPCTargetingHandler.server.luau"

# StarterPlayerScripts
sync_script "game.StarterPlayer.StarterPlayerScripts.NPCVisualsHandler" "$SRC_DIR/playerscripts/NPCVisualsHandler.luau"
sync_script "game.StarterPlayer.StarterPlayerScripts.TileCursor" "$SRC_DIR/playerscripts/TileCursor.luau"
sync_script "game.StarterPlayer.StarterPlayerScripts.TileClickHandler" "$SRC_DIR/playerscripts/TileClickHandler.luau"
sync_script "game.StarterPlayer.StarterPlayerScripts.TileVisualEffects" "$SRC_DIR/playerscripts/TileVisualEffects.luau"

# Client GUI scripts
sync_script "game.StarterGui.BuyNPCGui.BuyNPCGui" "$SRC_DIR/client/BuyNPCGui.client.luau"
sync_script "game.StarterGui.CountrySelectionScreen.CountrySelectionScreen" "$SRC_DIR/client/CountrySelectionScreen.client.luau"
sync_script "game.StarterGui.DiplomacyGui.DiplomacyGui" "$SRC_DIR/client/DiplomacyGui.client.luau"
sync_script "game.StarterGui.NotificationGui.NotificationGui" "$SRC_DIR/client/NotificationGui.client.luau"

echo "✨ Studio to local sync complete!"
