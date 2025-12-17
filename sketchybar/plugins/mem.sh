#!/bin/bash
# Calculate memory usage (requires the 'vm_stat' command output parsing)
# A simple approximation
MEM_USED=$(vm_stat | grep "Pages active" | awk '{print $3 * 4096 / 1024 / 1024 / 1024}')
MEM_FREE=$(vm_stat | grep "Pages free" | awk '{print $3 * 4096 / 1024 / 1024 / 1024}')
MEM_TOTAL=$(bc <<< "$MEM_USED + $MEM_FREE")
MEM_PERCENT=$(bc <<< "scale=1; ($MEM_USED / $MEM_TOTAL) * 100")

sketchybar --set "$NAME" label="MEM: ${MEM_PERCENT}%"
