#!/bin/bash
# Toggle between dwindle (tiles) and master (accordion) layout

LAYOUT=$(hyprctl getoption general:layout | grep -oP 'str: "\K[^"]+')

if [ "$LAYOUT" = "dwindle" ]; then
  hyprctl keyword general:layout master
else
  hyprctl keyword general:layout dwindle
fi
