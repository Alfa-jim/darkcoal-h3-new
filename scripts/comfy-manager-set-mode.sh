#!/usr/bin/env bash
MODE="${1:-offline}"
CFG="/comfyui/custom_nodes/ComfyUI-Manager/config.ini"
mkdir -p "$(dirname "$CFG")"
if [ -f "$CFG" ]; then
  if grep -q "network_mode" "$CFG"; then sed -i "s/^network_mode=.*/network_mode=$MODE/" "$CFG"
  else echo "network_mode=$MODE" >> "$CFG"; fi
else echo -e "[default]\nnetwork_mode=$MODE" > "$CFG"; fi
echo "ComfyUI-Manager mode=$MODE"
