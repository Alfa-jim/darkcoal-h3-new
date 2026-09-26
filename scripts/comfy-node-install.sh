#!/usr/bin/env bash
set -e
# helper to install extra ComfyUI nodes
if [ $# -eq 0 ]; then echo "usage: $0 <git-url> [extra pip args]"; exit 1; fi
URL="$1"; shift
NAME=$(basename "$URL" .git)
DST="/comfyui/custom_nodes/$NAME"
[ -d "$DST" ] || git clone "$URL" "$DST"
[ -f "$DST/requirements.txt" ] && uv pip install -r "$DST/requirements.txt" || true
echo "installed $NAME"
