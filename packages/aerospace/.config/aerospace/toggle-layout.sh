#!/bin/bash
# Toggle between tiles and accordion layout for the focused workspace

CURRENT=$("${HOME}/opt/aerospace-src/.debug/aerospace" list-windows --focused --format '%{window-layout}' 2>/dev/null)

if [[ "$CURRENT" == *accordion* ]]; then
  "${HOME}/opt/aerospace-src/.debug/aerospace" layout h_tiles
else
  "${HOME}/opt/aerospace-src/.debug/aerospace" layout v_accordion
fi
