#!/bin/bash
# Toggle between tiles and accordion layout for the focused workspace

CURRENT=$(aerospace list-windows --focused --format '%{window-layout}' 2>/dev/null)

if [[ "$CURRENT" == *accordion* ]]; then
  aerospace layout tiles horizontal vertical
else
  aerospace layout v_accordion
fi
