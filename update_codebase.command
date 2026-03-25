#!/bin/bash
cd "$(dirname "$0")"
find src -type f \( -name "*.lua" -o -name "*.luau" \) -exec sh -c 'echo ""; echo "--- {} ---"; cat "{}"' \; > codebase.txt
