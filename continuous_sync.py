#!/usr/bin/env python3
"""
Continuous background sync: Roblox Studio -> Local files
This script runs continuously and automatically syncs changes from Studio
"""

import os
import sys
import time
import hashlib
from pathlib import Path
from datetime import datetime

# Import the sync functionality
try:
    from studio_to_local_sync import SCRIPT_MAPPINGS, read_script_from_studio, sync_script_to_local
except ImportError:
    print("❌ Could not import sync functions. Make sure studio_to_local_sync.py exists.")
    sys.exit(1)

# Configuration
SYNC_INTERVAL = 10  # seconds between sync checks
LOG_FILE = "studio_sync.log"

# Track file hashes to detect actual changes
file_hashes = {}

def get_file_hash(content):
    """Get MD5 hash of file content"""
    return hashlib.md5(content.encode('utf-8')).hexdigest()

def log_message(message):
    """Log message with timestamp"""
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    log_entry = f"[{timestamp}] {message}"
    print(log_entry)
    
    # Also write to log file
    with open(LOG_FILE, 'a') as f:
        f.write(log_entry + '\n')

def check_for_changes():
    """Check for changes in Studio scripts and sync if needed"""
    changes_detected = False
    
    for studio_path, local_path in SCRIPT_MAPPINGS.items():
        try:
            # Read current content from Studio
            studio_content = read_script_from_studio(studio_path)
            if studio_content is None:
                continue
            
            # Calculate hash of Studio content
            studio_hash = get_file_hash(studio_content)
            
            # Check if we have a previous hash for this file
            previous_hash = file_hashes.get(studio_path)
            
            if previous_hash is None:
                # First time seeing this file
                file_hashes[studio_path] = studio_hash
                log_message(f"📝 Tracking new file: {studio_path}")
                changes_detected = True
            elif previous_hash != studio_hash:
                # File has changed
                log_message(f"🔄 Change detected in {studio_path}")
                
                # Sync the file
                if sync_script_to_local(studio_path, local_path):
                    file_hashes[studio_path] = studio_hash
                    changes_detected = True
                else:
                    log_message(f"❌ Failed to sync {studio_path}")
                    
        except Exception as e:
            log_message(f"⚠️  Error checking {studio_path}: {e}")
    
    return changes_detected

def main():
    """Main continuous sync loop"""
    # Initialize log file
    with open(LOG_FILE, 'w') as f:
        f.write("=== Roblox Studio Continuous Sync Log ===\n")
        f.write(f"Started: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"Sync interval: {SYNC_INTERVAL}s\n")
        f.write(f"Tracking {len(SCRIPT_MAPPINGS)} scripts\n\n")
    
    log_message("🚀 Starting continuous Roblox Studio sync...")
    log_message(f"📁 Monitoring {len(SCRIPT_MAPPINGS)} scripts for changes")
    log_message(f"⏹️  Press Ctrl+C to stop")
    log_message(f"📋 Logs: {LOG_FILE}")
    
    # Initial sync - get baseline hashes
    log_message("🔍 Establishing baseline...")
    check_for_changes()
    
    log_message(f"⏳ Now monitoring for changes every {SYNC_INTERVAL} seconds...")
    
    try:
        while True:
            time.sleep(SYNC_INTERVAL)
            
            if check_for_changes():
                log_message("✅ Changes synced successfully")
            else:
                # Only log "no changes" periodically to avoid spam
                if int(time.time()) % 60 == 0:  # Every minute
                    log_message("📭 No changes detected")
                    
    except KeyboardInterrupt:
        log_message("🛑 Stopping continuous sync...")
        log_message("👋 Goodbye!")
    except Exception as e:
        log_message(f"💥 Fatal error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
