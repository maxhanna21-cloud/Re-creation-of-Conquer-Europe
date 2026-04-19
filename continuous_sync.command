#!/bin/bash
# Continuous background sync: Roblox Studio -> Local files
# This script runs continuously and automatically syncs changes from Studio

cd "$(dirname "$0")"

echo "🔄 Starting continuous Roblox Studio sync..."
echo "📁 Monitoring for script changes and syncing automatically"
echo "⏹️  Press Ctrl+C to stop the continuous sync"
echo ""

# Configuration
SYNC_INTERVAL=10  # seconds between sync checks
LOG_FILE="studio_sync.log"

# Function to get current timestamp
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Function to run sync and log results
run_sync() {
    echo "[$(timestamp)] 🔍 Checking for changes..." | tee -a "$LOG_FILE"
    
    # Run the sync script
    if ./sync_from_studio.command >> "$LOG_FILE" 2>&1; then
        echo "[$(timestamp)] ✅ Sync completed" | tee -a "$LOG_FILE"
    else
        echo "[$(timestamp)] ❌ Sync failed" | tee -a "$LOG_FILE"
    fi
}

# Create log file header
echo "=== Roblox Studio Continuous Sync Log ===" > "$LOG_FILE"
echo "Started: $(timestamp)" >> "$LOG_FILE"
echo "Sync interval: ${SYNC_INTERVAL}s" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Initial sync
echo "🚀 Running initial sync..."
run_sync

echo ""
echo "⏳ Now monitoring for changes every ${SYNC_INTERVAL} seconds..."
echo "📋 Logs are being written to: $LOG_FILE"
echo ""

# Main loop - continuous sync
while true; do
    sleep "$SYNC_INTERVAL"
    run_sync
done
