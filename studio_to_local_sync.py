#!/usr/bin/env python3
"""
Bidirectional sync: Roblox Studio -> Local files
This script uses the Roblox Studio MCP to read scripts and write them to local .luau files
"""

import os
import sys
import json
import subprocess
from pathlib import Path

# Script mappings from Studio paths to local file paths
SCRIPT_MAPPINGS = {
    # ServerScriptService - Shared modules
    "game.ServerScriptService.DiplomacyManager": "src/shared/DiplomacyManager.luau",
    "game.ServerScriptService.NPCCombatSystem": "src/shared/NPCCombatSystem.luau", 
    "game.ServerScriptService.NPCMovementSystem": "src/shared/NPCMovementSystem.luau",
    "game.ServerScriptService.ServerState": "src/shared/ServerState.luau",
    "game.ServerScriptService.TileAdjacencyManager": "src/shared/TileAdjacencyManager.luau",
    "game.ServerScriptService.TileKeyUtils": "src/shared/TileKeyUtils.luau",
    "game.ServerScriptService.TileManager": "src/shared/TileManager.luau",
    "game.ServerScriptService.TileOwnershipManager": "src/shared/TileOwnershipManager.luau",
    "game.ServerScriptService.UnitManager": "src/shared/UnitManager.luau",
    
    # ServerScriptService - Server scripts
    "game.ServerScriptService.Auto-Fix": "src/server/Auto-Fix.server.luau",
    "game.ServerScriptService.CollisionSetup": "src/server/CollisionSetup.server.luau",
    "game.ServerScriptService.CountryManager": "src/server/CountryManager.server.luau",
    "game.ServerScriptService.Diagnostics": "src/server/Diagnostics.server.luau",
    "game.ServerScriptService.DiplomacyServer": "src/server/DiplomacyServer.server.luau",
    "game.ServerScriptService.Leaderstats": "src/server/Leaderstats.server.luau",
    "game.ServerScriptService.CountryNPCRegistry": "src/server/CountryNPCRegistry.luau",
    "game.ServerScriptService.NPCPurchaseHandler": "src/server/NPCPurchaseHandler.server.luau",
    "game.ServerScriptService.NPCSpawner": "src/server/NPCSpawner.luau",
    "game.ServerScriptService.NPCTargetingHandler": "src/server/NPCTargetingHandler.server.luau",
    
    # StarterPlayerScripts
    "game.StarterPlayer.StarterPlayerScripts.NPCVisualsHandler": "src/playerscripts/NPCVisualsHandler.luau",
    "game.StarterPlayer.StarterPlayerScripts.TileCursor": "src/playerscripts/TileCursor.luau",
    "game.StarterPlayer.StarterPlayerScripts.TileClickHandler": "src/playerscripts/TileClickHandler.luau",
    "game.StarterPlayer.StarterPlayerScripts.TileVisualEffects": "src/playerscripts/TileVisualEffects.luau",
    
    # Client GUI scripts
    "game.StarterGui.BuyNPCGui.BuyNPCGui": "src/client/BuyNPCGui.client.luau",
    "game.StarterGui.CountrySelectionScreen.CountrySelectionScreen": "src/client/CountrySelectionScreen.client.luau",
    "game.StarterGui.DiplomacyGui.DiplomacyGui": "src/client/DiplomacyGui.client.luau",
    "game.StarterGui.NotificationGui.NotificationGui": "src/client/NotificationGui.client.luau",
}

def read_script_from_studio(studio_path):
    """Read a script from Studio using MCP tools"""
    try:
        # Call the MCP script_read function
        result = subprocess.run([
            'mcp', 'call', 'Roblox_Studio', 'script_read',
            json.dumps({'target_file': studio_path, 'should_read_entire_file': True})
        ], capture_output=True, text=True, cwd=os.path.dirname(os.path.abspath(__file__)))
        
        if result.returncode == 0:
            # Parse the JSON response
            response = json.loads(result.stdout)
            if 'content' in response:
                return response['content']
        
        return None
    except Exception as e:
        print(f"    ❌ Error reading {studio_path}: {e}")
        return None

def sync_script_to_local(studio_path, local_path):
    """Read a script from Studio and write it to local file"""
    print(f"  📝 Syncing {studio_path} -> {local_path}")
    
    # Read from Studio
    content = read_script_from_studio(studio_path)
    if content is None:
        print(f"    ❌ Failed to read from Studio: {studio_path}")
        return False
    
    # Create directory if it doesn't exist
    local_file = Path(local_path)
    local_file.parent.mkdir(parents=True, exist_ok=True)
    
    # Write to local file
    try:
        with open(local_file, 'w') as f:
            f.write(content)
        
        line_count = len(content.splitlines())
        print(f"    ✅ Synced {line_count} lines")
        return True
        
    except Exception as e:
        print(f"    ❌ Failed to write to {local_path}: {e}")
        return False

def main():
    """Main sync function"""
    print("🔄 Starting Studio to local sync...")
    
    synced_count = 0
    total_count = len(SCRIPT_MAPPINGS)
    
    for studio_path, local_path in SCRIPT_MAPPINGS.items():
        if sync_script_to_local(studio_path, local_path):
            synced_count += 1
    
    print(f"✨ Studio to local sync complete!")
    print(f"📊 Synced {synced_count}/{total_count} files")

if __name__ == "__main__":
    main()
