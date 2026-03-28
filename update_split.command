#!/bin/bash
cd "$(dirname "$0")"
TOP_N=10

# Rank all .luau/.lua files by line count, take top N file paths
top_files=$(find src -type f \( -name "*.lua" -o -name "*.luau" \) \
  -exec wc -l {} \; | sort -rn | head -n "$TOP_N" | awk '{print $2}')

# Output largescripts.txt (top N files)
> largescripts.txt
while IFS= read -r f; do
  echo ""
  echo "--- $f ---"
  cat "$f"
done <<< "$top_files" >> largescripts.txt

# Output restofcodebase.txt (everything NOT in top N)
> restofcodebase.txt
find src -type f \( -name "*.lua" -o -name "*.luau" \) | while IFS= read -r f; do
  if ! echo "$top_files" | grep -qF "$f"; then
    echo ""
    echo "--- $f ---"
    cat "$f"
  fi
done >> restofcodebase.txt
