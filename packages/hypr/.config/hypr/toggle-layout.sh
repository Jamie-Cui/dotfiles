#!/bin/bash
# Toggle the focused workspace between dwindle and monocle layout

set -euo pipefail

workspace_json=$(hyprctl -j activeworkspace)
workspace_id=$(jq -r '.id' <<<"$workspace_json")
layout=$(jq -r '.tiledLayout' <<<"$workspace_json")

case "$layout" in
  dwindle)
    next_layout=monocle
    ;;
  monocle)
    next_layout=dwindle
    ;;
  *)
    exit 1
    ;;
esac

hyprctl keyword workspace "$workspace_id,layout:$next_layout"
