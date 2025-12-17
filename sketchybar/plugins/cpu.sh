#!/bin/bash
# Calculate total CPU usage
CPU_USAGE=$(ps -A -o %cpu | awk '{s+=$1} END {printf "%.1f%%", s}')
sketchybar --set "$NAME" label="CPU: $CPU_USAGE"
