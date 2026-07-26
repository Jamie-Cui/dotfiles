#!/bin/bash
# Toggle between default (tiles) and stacking (accordion) layout for the focused container

LAYOUT=$(i3-msg -t get_tree | jq -r '.. | select(.focused? == true) | .layout' 2>/dev/null)

if [ "$LAYOUT" = "stacked" ]; then
  i3-msg layout default
else
  i3-msg layout stacking
fi
