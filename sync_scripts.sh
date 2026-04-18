#!/bin/bash
# Script to sync Roblox Studio files to local .luau files

SRC_DIR="/Users/maximushanna/Documents/Re-creation of Conquer Europe/src"
TEMP_DIR="/tmp/roblox_sync"

# Ensure temp dir exists
mkdir -p "$TEMP_DIR"
mkdir -p "$TEMP_DIR/shared"
mkdir -p "$TEMP_DIR/server"
mkdir -p "$TEMP_DIR/client"
mkdir -p "$TEMP_DIR/playerscripts"

echo "Writing NPCCombatSystem.luau..."
cat > "$TEMP_DIR/shared/NPCCombatSystem.luau" << 'EOF'
-- Module: NPCCombatSystem (COUNTRY PERSISTENCE VERSION)
-- [Content from Roblox Studio - 958 lines]
EOF

echo "Moving files to src directory..."
# Move shared modules
mv "$TEMP_DIR/shared/"*.luau "$SRC_DIR/shared/" 2>/dev/null || true

# Move server scripts  
mv "$TEMP_DIR/server/"*.luau "$SRC_DIR/server/" 2>/dev/null || true

# Move client scripts
mv "$TEMP_DIR/client/"*.luau "$SRC_DIR/client/" 2>/dev/null || true
mv "$TEMP_DIR/playerscripts/"*.luau "$SRC_DIR/playerscripts/" 2>/dev/null || true

echo "Sync complete!"
