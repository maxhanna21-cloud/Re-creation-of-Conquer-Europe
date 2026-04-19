#!/bin/bash
# File watcher: Monitors Roblox Studio for changes and syncs to local files
# This script runs continuously and watches for script modifications in Studio

cd "$(dirname "$0")"

echo "👁️  Starting Roblox Studio change watcher..."
echo "📁 Watching for script changes in Studio"
echo "⏹️  Press Ctrl+C to stop watching"

# Function to sync a single script when it changes
sync_on_change() {
    local studio_path="$1"
    local local_path="$2"
    
    echo ""
    echo "🔄 Change detected in $studio_path"
    
    # Run the sync script
    ./studio_sync.py
    
    echo "⏸️  Waiting for next change..."
}

# Monitor Studio for script changes using fswatch or similar
# For now, we'll use a simple polling approach with the MCP tools
POLL_INTERVAL=5  # seconds

while true; do
    echo "🔍 Checking for Studio changes..."
    
    # Check if Studio is running and accessible
    if python3 -c "
import sys
try:
    # Try to connect to Studio MCP
    import subprocess
    result = subprocess.run(['mcp', 'list-servers'], capture_output=True, text=True)
    if 'Roblox_Studio' in result.stdout:
        print('Studio connected')
        sys.exit(0)
    else:
        print('Studio not connected')
        sys.exit(1)
except:
    print('MCP not available')
    sys.exit(1)
" 2>/dev/null; then
        
        # Studio is connected, check for changes
        echo "  ✅ Studio is connected"
        
        # Run sync to check for changes (this would be enhanced to detect actual changes)
        ./studio_sync.py
        
    else
        echo "  ⚠️  Studio not connected, waiting..."
    fi
    
    echo "⏳ Waiting $POLL_INTERVAL seconds..."
    sleep $POLL_INTERVAL
done
