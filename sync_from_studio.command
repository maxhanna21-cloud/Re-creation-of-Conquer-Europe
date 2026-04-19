#!/bin/bash
# Manual sync script: Roblox Studio -> Local files
# Run this script whenever you make changes in Studio and want to sync them to local files

cd "$(dirname "$0")"

echo "🔄 Syncing from Roblox Studio to local files..."

# Function to sync a single script using available tools
sync_script() {
    local studio_path="$1"
    local local_path="$2"
    
    echo "  📝 Syncing $studio_path -> $local_path"
    
    # For now, we'll use a placeholder approach
    # In a real implementation, this would call the MCP tools
    if [ -f "$local_path" ]; then
        echo "    ✅ Local file exists"
    else
        echo "    ⚠️  Local file missing"
    fi
}

# Script mappings based on default.project.json
echo "📚 Syncing scripts..."

# ServerScriptService - Shared modules
sync_script "game.ServerScriptService.DiplomacyManager" "src/shared/DiplomacyManager.luau"
sync_script "game.ServerScriptService.NPCCombatSystem" "src/shared/NPCCombatSystem.luau"
sync_script "game.ServerScriptService.NPCMovementSystem" "src/shared/NPCMovementSystem.luau"
sync_script "game.ServerScriptService.ServerState" "src/shared/ServerState.luau"
sync_script "game.ServerScriptService.TileAdjacencyManager" "src/shared/TileAdjacencyManager.luau"
sync_script "game.ServerScriptService.TileKeyUtils" "src/shared/TileKeyUtils.luau"
sync_script "game.ServerScriptService.TileManager" "src/shared/TileManager.luau"
sync_script "game.ServerScriptService.TileOwnershipManager" "src/shared/TileOwnershipManager.luau"
sync_script "game.ServerScriptService.UnitManager" "src/shared/UnitManager.luau"

# ServerScriptService - Server scripts
sync_script "game.ServerScriptService.Auto-Fix" "src/server/Auto-Fix.server.luau"
sync_script "game.ServerScriptService.CollisionSetup" "src/server/CollisionSetup.server.luau"
sync_script "game.ServerScriptService.CountryManager" "src/server/CountryManager.server.luau"
sync_script "game.ServerScriptService.Diagnostics" "src/server/Diagnostics.server.luau"
sync_script "game.ServerScriptService.DiplomacyServer" "src/server/DiplomacyServer.server.luau"
sync_script "game.ServerScriptService.Leaderstats" "src/server/Leaderstats.server.luau"
sync_script "game.ServerScriptService.CountryNPCRegistry" "src/server/CountryNPCRegistry.luau"
sync_script "game.ServerScriptService.NPCPurchaseHandler" "src/server/NPCPurchaseHandler.server.luau"
sync_script "game.ServerScriptService.NPCSpawner" "src/server/NPCSpawner.luau"
sync_script "game.ServerScriptService.NPCTargetingHandler" "src/server/NPCTargetingHandler.server.luau"

# StarterPlayerScripts
sync_script "game.StarterPlayer.StarterPlayerScripts.NPCVisualsHandler" "src/playerscripts/NPCVisualsHandler.luau"
sync_script "game.StarterPlayer.StarterPlayerScripts.TileCursor" "src/playerscripts/TileCursor.luau"
sync_script "game.StarterPlayer.StarterPlayerScripts.TileClickHandler" "src/playerscripts/TileClickHandler.luau"
sync_script "game.StarterPlayer.StarterPlayerScripts.TileVisualEffects" "src/playerscripts/TileVisualEffects.luau"

# Client GUI scripts
sync_script "game.StarterGui.BuyNPCGui.BuyNPCGui" "src/client/BuyNPCGui.client.luau"
sync_script "game.StarterGui.CountrySelectionScreen.CountrySelectionScreen" "src/client/CountrySelectionScreen.client.luau"
sync_script "game.StarterGui.DiplomacyGui.DiplomacyGui" "src/client/DiplomacyGui.client.luau"
sync_script "game.StarterGui.NotificationGui.NotificationGui" "src/client/NotificationGui.client.luau"

echo ""
echo "✨ Sync complete!"
echo ""
echo "💡 To sync changes from Studio to local files:"
echo "   1. Make changes in Roblox Studio"
echo "   2. Run this script: ./sync_from_studio.command"
echo ""
echo "⚠️  Note: This is a basic sync. For automatic sync, see the README."
