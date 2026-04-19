#!/bin/bash
# Launcher for continuous Roblox Studio sync
# This script starts the background sync process

cd "$(dirname "$0")"

echo "🚀 Starting Roblox Studio continuous sync..."
echo ""
echo "📋 Available options:"
echo "1. Simple timer-based sync (./continuous_sync.command)"
echo "2. Smart change detection sync (./continuous_sync.py)"
echo ""
read -p "Choose option (1 or 2, default=2): " choice

case $choice in
    1)
        echo "🔄 Starting simple timer-based sync..."
        ./continuous_sync.command
        ;;
    2|"" )
        echo "🧠 Starting smart change detection sync..."
        python3 continuous_sync.py
        ;;
    *)
        echo "❌ Invalid choice. Starting smart sync..."
        python3 continuous_sync.py
        ;;
esac
