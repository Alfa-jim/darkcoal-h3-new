#!/usr/bin/env bash
# ==============================================================================
# darkcoal-h3-new — POD bake for Network Volume (uses /workspace, NOT /runpod-volume)
# ==============================================================================
# PURPOSE: Download the 11.6GB Q4_K_M Ref2VA GGUF into your Network Volume so
#          Serverless workers see it at /runpod-volume/models/...
#
# MOUNT BEHAVIOUR (RunPod):
#   • POD terminal     -> /workspace  (this script writes HERE per user instruction)
#   • SERVERLESS worker-> /runpod-volume  (same volume, different mount point)
#   Script writes to /workspace and cross-links to /runpod-volume for compat.
#
# SOURCES (both pruned Ref2VA Q4 — either works with UnetLoaderGGUF):
#   • PRIMARY (ComfyUI-friendly name): Abiray/MiniMax-H3-Pruned-GGUF
#     File: MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf  (11.6 GB, Q4_K_M)
#   • UPSTREAM per https://huggingface.co/unsloth/MiniMax-H3-GGUF :
#     Repo: unsloth/MiniMax-H3-GGUF
#     File: minimax_h3_ref2va_pruned-Q4_K.gguf  (same architecture, alt quant name)
#
# USAGE:
#   1) RunPod Console → Pods → Deploy → Community → RTX 4090 (CPU fine, no GPU needed)
#      → Attach Network Volume: darkcoal-h3  20 GB  (same region as future Serverless endpoint)
#      → Deploy
#   2) Connect → Terminal → paste ENTIRE file and run:
#        bash POD_BAKE_COMMAND.sh
#      Re-run if SSH drops — resumes safely.
#   3) Wait 3-7 min. When you see  === SUCCESS  → STOP / TERMINATE the Pod
#      (Network Volume persists). Deploy Serverless with SAME volume.
#
# REQUIRED SPACE: 20 GB minimum (11.6GB + HF 2x temp).
# ==============================================================================
set -e

# ── Which GGUF to bake ────────────────────────────────────────────────────────
# Default: Abiray Q4_K_M (stable ComfyUI name). Switch to unsloth by uncommenting.
REPO="Abiray/MiniMax-H3-Pruned-GGUF"
FILE="MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf"
# REPO="unsloth/MiniMax-H3-GGUF"
# FILE="minimax_h3_ref2va_pruned-Q4_K.gguf"
EXPECTED_GB="11.6"
EXPECTED_BYTES=12460000000

# Alt unsloth pair (downloaded as secondary if primary already exists logic is skipped;
# we bake ONLY the primary; comment above to bake unsloth instead)
ALT_REPO="unsloth/MiniMax-H3-GGUF"
ALT_FILE="minimax_h3_ref2va_pruned-Q4_K.gguf"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; DIM='\033[0;90m'; NC='\033[0m'

echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  darkcoal-h3-new — Ref2VA Q4 bake → /workspace (Pod)      ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo "Repo: $REPO"; echo "File: $FILE"; echo ""

# ── Detect mount ──────────────────────────────────────────────────────────────
VOLUME="/workspace"
if [ -d "/workspace" ]; then VOLUME="/workspace"
elif [ -d "/runpod-volume" ]; then VOLUME="/runpod-volume"
else
  echo -e "${RED}ERROR: no /workspace or /runpod-volume${NC}"
  echo "Attach the Network Volume to this Pod! Console → Pods → attach volume (Network, 20GB, same region)"
  exit 1
fi
SECONDARY=""
if [ "$VOLUME" = "/workspace" ] && [ -d "/runpod-volume" ]; then SECONDARY="/runpod-volume"; fi
if [ "$VOLUME" = "/runpod-volume" ] && [ -d "/workspace" ]; then SECONDARY="/workspace"; fi

TARGET_DIR="$VOLUME/models/diffusion_models"
TARGET_FILE="$TARGET_DIR/$FILE"
UNET_LINK="$VOLUME/models/unet/$FILE"

echo -e "${GREEN}Primary:${NC} $VOLUME"
[ -n "$SECONDARY" ] && echo -e "${GREEN}Secondary:${NC} $SECONDARY"
echo -e "${DIM}Target: $TARGET_FILE${NC}"
df -h "$VOLUME" | tail -1 | awk '{print "Size " $2 "  Used " $3 "  Free " $4}'
echo ""

mkdir -p "$TARGET_DIR" "$VOLUME/models/unet"
[ -n "$SECONDARY" ] && mkdir -p "$SECONDARY/models/diffusion_models" "$SECONDARY/models/unet"

# ── Already exists? ───────────────────────────────────────────────────────────
if [ -f "$TARGET_FILE" ]; then
  SIZE=$(stat -c%s "$TARGET_FILE" 2>/dev/null || stat -f%z "$TARGET_FILE" 2>/dev/null || echo 0)
  SGB=$(awk "BEGIN{printf \"%.2f\", $SIZE/1024/1024/1024}")
  echo -e "${YELLOW}Already exists: $SGB GB${NC}"
  if [ "$SIZE" -gt $((EXPECTED_BYTES - 800000000)) ] && [ "$SIZE" -lt $((EXPECTED_BYTES + 800000000)) ]; then
    if head -c 4 "$TARGET_FILE" 2>/dev/null | grep -q "GGUF" 2>/dev/null; then
      echo -e "${GREEN}GGUF magic OK — fixing symlinks...${NC}"
      ln -sf "$TARGET_FILE" "$UNET_LINK"
      if [ -n "$SECONDARY" ]; then
        ln -sf "$TARGET_FILE" "$SECONDARY/models/diffusion_models/$FILE" 2>/dev/null || true
        ln -sf "$SECONDARY/models/diffusion_models/$FILE" "$SECONDARY/models/unet/$FILE" 2>/dev/null || true
        mkdir -p /runpod-volume 2>/dev/null || true
        [ -e "/runpod-volume/models" ] || ln -sf "$VOLUME/models" /runpod-volume/models 2>/dev/null || true
      fi
      ls -lh "$TARGET_FILE" "$UNET_LINK"
      echo ""; echo -e "${GREEN}=== SUCCESS — already baked ===${NC}"; echo "  $TARGET_FILE"; echo "  Serverless: /runpod-volume/models/diffusion_models/$FILE"; exit 0
    else
      echo -e "${YELLOW}Header invalid — re-downloading${NC}"; rm -f "$TARGET_FILE"
    fi
  else
    echo -e "${YELLOW}Size mismatch (~$EXPECTED_GB GB vs $SGB) — resuming${NC}"
  fi
fi

# ── Install tools ─────────────────────────────────────────────────────────────
echo -e "${GREEN}Installing hf tools...${NC}"
pip install -q --upgrade huggingface_hub hf_transfer 2>&1 | tail -1 || pip install -q huggingface_hub
export HF_HUB_ENABLE_HF_TRANSFER=1

# ── Download ──────────────────────────────────────────────────────────────────
echo -e "${GREEN}Downloading (resumable)...${NC}"
echo "If SSH drops, re-run this script — it resumes."
echo ""
set +e
if command -v huggingface-cli >/dev/null 2>&1; then
  huggingface-cli download "$REPO" "$FILE" --local-dir "$TARGET_DIR" --local-dir-use-symlinks False 2>&1
  HF_EXIT=$?
else HF_EXIT=127; fi
if [ $HF_EXIT -ne 0 ] || [ ! -f "$TARGET_FILE" ]; then
  echo -e "${YELLOW}huggingface-cli failed (exit $HF_EXIT) — fallback wget/aria2c...${NC}"
  URL="https://huggingface.co/$REPO/resolve/main/$FILE"
  if command -v aria2c >/dev/null 2>&1; then
    aria2c -x16 -s16 -c --file-allocation=none --summary-interval=1 -d "$TARGET_DIR" -o "$FILE" "$URL"; DL_EXIT=$?
  else
    wget -c --progress=bar:force --tries=5 --timeout=30 -O "$TARGET_FILE.tmp" "$URL"; DL_EXIT=$?
    [ $DL_EXIT -eq 0 ] && [ -f "$TARGET_FILE.tmp" ] && mv -f "$TARGET_FILE.tmp" "$TARGET_FILE"
  fi
  [ "$DL_EXIT" -ne 0 ] && echo -e "${RED}Download failed — re-run to resume${NC}" && exit 1
fi
set -e

# ── Verify + symlink ──────────────────────────────────────────────────────────
[ -f "$TARGET_FILE" ] || { FOUND=$(find "$TARGET_DIR" -name "$FILE" -type f 2>/dev/null | head -1); [ -n "$FOUND" ] && mv -f "$FOUND" "$TARGET_FILE" || { echo -e "${RED}Not found after download${NC}"; ls -lh "$TARGET_DIR"; exit 1; }; }
SIZE=$(stat -c%s "$TARGET_FILE" 2>/dev/null || stat -f%z "$TARGET_FILE"); SGB=$(awk "BEGIN{printf \"%.2f\", $SIZE/1024/1024/1024}")
echo -e "${GREEN}Downloaded $SGB GB → $TARGET_FILE${NC}"; ls -lh "$TARGET_FILE"
ln -sf "$TARGET_FILE" "$UNET_LINK"; echo -e "${GREEN}Symlink $UNET_LINK → $TARGET_FILE${NC}"; ls -lh "$UNET_LINK"
if [ -n "$SECONDARY" ]; then
  echo -e "${GREEN}Cross-linking $SECONDARY...${NC}"
  ln -sf "$TARGET_FILE" "$SECONDARY/models/diffusion_models/$FILE" 2>/dev/null || true
  ln -sf "$SECONDARY/models/diffusion_models/$FILE" "$SECONDARY/models/unet/$FILE" 2>/dev/null || true
  mkdir -p /runpod-volume 2>/dev/null || true
  [ -e "/runpod-volume/models" ] || ln -sf "$VOLUME/models" /runpod-volume/models 2>/dev/null || true
fi

# ── Also bake unsloth VAE helpers (tiny, optional but useful) ───────────────
echo ""
echo -e "${DIM}Fetching VAE helpers (optional, from unsloth) — ignore errors if offline${DIM}"
mkdir -p "$VOLUME/models/vae" 2>/dev/null || true
huggingface-cli download unsloth/MiniMax-H3-GGUF vae/minimax_h3_video_vae_fp16.safetensors --local-dir "$VOLUME/models/vae" --local-dir-use-symlinks False 2>&1 | tail -3 || true
huggingface-cli download unsloth/MiniMax-H3-GGUF vae/minimax_h3_audio_vae_fp32.safetensors --local-dir "$VOLUME/models/vae" --local-dir-use-symlinks False 2>&1 | tail -3 || true
[ -n "$SECONDARY" ] && mkdir -p "$SECONDARY/models/vae" 2>/dev/null || true

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  === SUCCESS — volume baked ===                           ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo "  Primary:   $TARGET_FILE"
echo "  Symlink:   $UNET_LINK"
[ -n "$SECONDARY" ] && echo "  Secondary: $SECONDARY/models/diffusion_models/$FILE"
echo "  Serverless sees: /runpod-volume/models/diffusion_models/$FILE"
echo "  Serverless sees: /runpod-volume/models/unet/$FILE"
echo ""
echo -e "${GREEN}You can now STOP/TERMINATE this Pod — Network Volume persists.${NC}"
echo "Next: Serverless Endpoint → Container ghcr.io/alfa-jim/darkcoal-h3-new:latest"
echo "  Attach SAME volume (20GB, same region/datacenter!)  Disk 25GB  GPU A6000/4090  Min 0 Max 2 Idle 5s Exec 300s"
echo "  Test with playground.html  → endpoint runsync + key"
echo ""
echo -e "${DIM}Tip: to bake unsloth naming instead, edit REPO/FILE at top of this script to:${DIM}"
echo -e "${DIM}  REPO=\"unsloth/MiniMax-H3-GGUF\"  FILE=\"minimax_h3_ref2va_pruned-Q4_K.gguf\"${DIM}"
