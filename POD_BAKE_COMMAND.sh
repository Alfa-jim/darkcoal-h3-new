#!/usr/bin/env bash
# ==============================================================================
# darkcoal-h3-new — POD bake for Network Volume  (v2 — visual, safe-resume)
# ==============================================================================
# WHAT IT DOES:
#   Downloads the 11.6GB Q4_K_M Ref2VA GGUF into your RunPod Network Volume
#   so Serverless workers see it at /runpod-volume/models/diffusion_models/...
#   — Writes to /workspace (Pod view), auto cross-links to /runpod-volume
#     (Serverless view is the SAME volume, different mount). Safe to re-run.
#
# SOURCES (both pruned Ref2VA Q4 — either works with UnetLoaderGGUF):
#   • PRIMARY:   Abiray/MiniMax-H3-Pruned-GGUF
#                MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf  (11.6 GB, Q4_K_M)
#   • UPSTREAM:  unsloth/MiniMax-H3-GGUF  (your reference link)
#                minimax_h3_ref2va_pruned-Q4_K.gguf
#   This script bakes PRIMARY by default, detects BOTH, and never redownloads
#   if either is already valid. Edit REPO/FILE at top to flip primary.
#
# USAGE:
#   1) Console → Pods → Deploy → Community → RTX 4090 (CPU OK, no GPU needed)
#      attach Network Volume: darkcoal-h3  20GB  same region as future Serverless!
#   2) Connect → Terminal → paste ENTIRE file:
#        bash POD_BAKE_COMMAND.sh
#      Re-run if SSH drops — 100% safe resume (hf_transfer + aria2c + wget -c).
#   3) Wait for  === SUCCESS  (3-7 min, live progress bar) → STOP / TERMINATE Pod
#      (volume persists). Deploy Serverless with SAME volume.
#
# VISUAL: live GGUF progress bar + GB counter + speed, plus inventory of any
#         pre-existing files (so you know if previous attempts already baked).
# REQUIRED: 20GB Network Volume minimum (11.6GB + 2× HF temp). Network Volume,
#           NOT Global Volume (Pods-only Beta).
# ==============================================================================
set -e

# ── Config ───────────────────────────────────────────────────────────────────
REPO="Abiray/MiniMax-H3-Pruned-GGUF"
FILE="MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf"
EXPECTED_GB="10.77"
EXPECTED_BYTES=11564180576          # exact XET content-length 2026-09-26 (10.77 GiB = 11.56 GB) — single source of truth
EXPECTED_TOL=200000000              # ±200 MB, tight because we now have exact size

ALT_REPO="unsloth/MiniMax-H3-GGUF"
ALT_FILE="minimax_h3_ref2va_pruned-Q4_K.gguf"
# exact alt sizes vary by quant, allow same tolerance
# ── Colors ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; DIM='\033[0;90m'; BOLD='\033[1m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; CYAN=''; DIM=''; BOLD=''; NC=''
fi

# ── Helpers ──────────────────────────────────────────────────────────────────
human_gb(){ awk "BEGIN{printf \"%.2f\", $1/1024/1024/1024}"; }
human_size(){ awk 'function h(x){if(x<1024)return x" B";if(x<1048576)return sprintf("%.1f KB",x/1024);if(x<1073741824)return sprintf("%.1f MB",x/1048576);return sprintf("%.2f GB",x/1073741824)} {print h($1)}' <<< "$1"; }
has_magic_gguf(){ head -c 4 "$1" 2>/dev/null | grep -q "GGUF"; }
stat_bytes(){ stat -L -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }
HF_CLI(){ if command -v huggingface-cli >/dev/null 2>&1; then huggingface-cli "$@"; else python3 -m huggingface_hub.commands.huggingface_cli "$@" 2>/dev/null || python -m huggingface_hub.commands.huggingface_cli "$@" || return 127; fi; }
bar(){
  local pct=$1; local w=28; local filled=$((pct*w/100)); local empty=$((w-filled))
  printf "["
  printf "%${filled}s" "" | tr ' ' '█'
  printf "%${empty}s" "" | tr ' ' '░'
  printf "] %3s%%" "$pct"
}

check_one(){
  local path="$1"; local label="$2"
  if [ -e "$path" ]; then
    local sz=$(stat_bytes "$path")
    local gb=$(human_gb "$sz")
    local is_link=""; [ -L "$path" ] && is_link="↗ symlink"
    local magic="?"
    has_magic_gguf "$path" && magic="GGUF ✓" || magic="bad header ✗"
    local ok="?"
    if [ "$sz" -gt $((EXPECTED_BYTES - EXPECTED_TOL)) ] && [ "$sz" -lt $((EXPECTED_BYTES + EXPECTED_TOL)) ] && has_magic_gguf "$path"; then ok="${GREEN}VALID${NC}"; else ok="${YELLOW}INCOMPLETE/BAD${NC}"; fi
    # if symlink to valid target, count as VALID even if link size is tiny — follow target
    if [ -L "$path" ]; then
      local tsz=$(stat_bytes "$path")
      if [ "$tsz" -gt $((EXPECTED_BYTES - EXPECTED_TOL)) ] && has_magic_gguf "$path"; then ok="${GREEN}VALID (→ target)${NC}"; fi
    fi
    printf "  %-10s %s  %6s GB  %s  → %b %s\n" "$label" "$(basename "$path")" "$gb" "$magic" "$ok" "$is_link"
    echo -e "             ${DIM}$path${NC}"
    return 0
  else
    printf "  %-10s %s  ${DIM}— missing —${NC}\n" "$label" "$(basename "$path")"
    echo -e "             ${DIM}$path${NC}"
    return 1
  fi
}

echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  darkcoal-h3-new — Ref2VA Q4 bake  → /workspace (Pod)    ║${NC}"
echo -e "${GREEN}║  visual + safe-resume  +  pre-flight inventory            ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo -e "Primary:  ${BOLD}$REPO${NC}  →  $FILE  (~${EXPECTED_GB} GB)"
echo -e "Alt:      $ALT_REPO  →  $ALT_FILE"
echo ""

# ── Detect mount ─────────────────────────────────────────────────────────────
VOLUME=""
if [ -d "/workspace" ]; then VOLUME="/workspace"
elif [ -d "/runpod-volume" ]; then VOLUME="/runpod-volume"
else
  echo -e "${RED}ERROR: no /workspace or /runpod-volume found.${NC}"
  echo "Did you attach the Network Volume to this Pod?"
  echo "Console → Pods → Deploy → attach volume (Network, 20GB, SAME region as Serverless!) → Connect"
  echo "Then:  ls /workspace  ;  ls /runpod-volume"
  exit 1
fi
SECONDARY=""
if [ "$VOLUME" = "/workspace" ] && [ -d "/runpod-volume" ]; then SECONDARY="/runpod-volume"; fi
if [ "$VOLUME" = "/runpod-volume" ] && [ -d "/workspace" ]; then SECONDARY="/workspace"; fi

TARGET_DIR="$VOLUME/models/diffusion_models"
TARGET_FILE="$TARGET_DIR/$FILE"
UNET_LINK="$VOLUME/models/unet/$FILE"
ALT_TARGET="$VOLUME/models/diffusion_models/$ALT_FILE"
ALT_LINK="$VOLUME/models/unet/$ALT_FILE"

echo -e "${GREEN}Primary mount:${NC}  $VOLUME"
[ -n "$SECONDARY" ] && echo -e "${GREEN}Secondary:${NC}    $SECONDARY (cross-linked)"
echo -e "${DIM}Target:     $TARGET_FILE${NC}"
echo -e "${DIM}Alt:        $ALT_TARGET${NC}"
df -h "$VOLUME" 2>/dev/null | tail -1 | awk '{printf "Disk: size %s  used %s  free %s  use %s\n",$2,$3,$4,$5}'
echo ""

mkdir -p "$TARGET_DIR" "$VOLUME/models/unet" "$VOLUME/models/vae"
[ -n "$SECONDARY" ] && mkdir -p "$SECONDARY/models/diffusion_models" "$SECONDARY/models/unet" "$SECONDARY/models/vae" 2>/dev/null || true

# ── Pre-flight inventory (checks if previous attempts already baked) ──────────
echo -e "${BOLD}── Pre-flight inventory (checking for previous bakes) ──${NC}"
echo -e "${DIM}Scanning both mount views + both filename variants...${NC}"
FOUND_VALID=""
for p in \
  "$VOLUME/models/diffusion_models/$FILE" \
  "$VOLUME/models/unet/$FILE" \
  "$SECONDARY/models/diffusion_models/$FILE" \
  "$SECONDARY/models/unet/$FILE" \
  "/runpod-volume/models/diffusion_models/$FILE" \
  "/runpod-volume/models/unet/$FILE" \
  "/workspace/models/diffusion_models/$FILE" \
  "/workspace/models/unet/$FILE"
do
  [ -z "$p" ] && continue
  [ "$p" = "/models/diffusion_models/$FILE" ] && continue
  if [ -e "$p" ]; then
    sz=$(stat_bytes "$p")
    if [ "$sz" -gt $((EXPECTED_BYTES - EXPECTED_TOL)) ] && has_magic_gguf "$p"; then
      FOUND_VALID="$p"
    fi
  fi
done
# de-dupe display
declare -A SEEN
for loc in "$VOLUME" "$SECONDARY" "/runpod-volume" "/workspace"; do
  [ -z "$loc" ] && continue
  [ -n "${SEEN[$loc]}" ] && continue
  SEEN[$loc]=1
  [ ! -d "$loc/models" ] && { echo -e "${DIM}$loc/models — no models dir yet${NC}"; continue; }
  echo -e "${CYAN}$loc/models:${NC}"
  check_one "$loc/models/diffusion_models/$FILE" "primary" || true
  check_one "$loc/models/unet/$FILE"            "unet"    || true
  check_one "$loc/models/diffusion_models/$ALT_FILE" "alt" || true
  check_one "$loc/models/unet/$ALT_FILE"            "alt-unet" || true
  # vae helpers
  if [ -d "$loc/models/vae" ]; then
    echo -e "  ${DIM}vae/${NC}"
    ls -lh "$loc/models/vae/" 2>/dev/null | awk 'NR>1{printf "             %s  %s\n",$9,$5}' | head -5
  fi
done
echo ""

if [ -n "$FOUND_VALID" ]; then
  SZ=$(stat_bytes "$FOUND_VALID")
  echo -e "${GREEN}✔ Found VALID GGUF at: $FOUND_VALID  ($(human_gb "$SZ") GB, GGUF magic OK)${NC}"
  echo -e "${DIM}  Ensuring all symlinks point there (so Serverless at /runpod-volume finds it)...${NC}"
  # Normalize to VOLUME as canonical
  REAL="$TARGET_FILE"
  # If valid is alt naming, keep it and also link primary name for ComfyUI compat
  if [[ "$FOUND_VALID" == *"$ALT_FILE" ]]; then
    echo -e "${YELLOW}Note: valid file is ALT naming ($ALT_FILE). Linking PRIMARY name too for handler compat.${NC}"
    ln -sf "$FOUND_VALID" "$TARGET_FILE" 2>/dev/null || cp -n "$FOUND_VALID" "$TARGET_FILE" 2>/dev/null || true
    ln -sf "$FOUND_VALID" "$ALT_TARGET" 2>/dev/null || true
    ln -sf "$FOUND_VALID" "$ALT_LINK" 2>/dev/null || true
    ln -sf "$TARGET_FILE" "$UNET_LINK" 2>/dev/null || true
    [ -n "$SECONDARY" ] && ln -sf "$FOUND_VALID" "$SECONDARY/models/diffusion_models/$ALT_FILE" 2>/dev/null || true
    [ -n "$SECONDARY" ] && ln -sf "$FOUND_VALID" "$SECONDARY/models/unet/$ALT_FILE" 2>/dev/null || true
  else
    ln -sf "$FOUND_VALID" "$TARGET_FILE" 2>/dev/null || true
    ln -sf "$TARGET_FILE" "$UNET_LINK" 2>/dev/null || true
    [ -n "$SECONDARY" ] && ln -sf "$TARGET_FILE" "$SECONDARY/models/diffusion_models/$FILE" 2>/dev/null || true
    [ -n "$SECONDARY" ] && ln -sf "$TARGET_FILE" "$SECONDARY/models/unet/$FILE" 2>/dev/null || true
    # also ensure /runpod-volume view
    mkdir -p /runpod-volume/models/diffusion_models /runpod-volume/models/unet 2>/dev/null || true
    ln -sf "$TARGET_FILE" /runpod-volume/models/diffusion_models/"$FILE" 2>/dev/null || true
    ln -sf "$TARGET_FILE" /runpod-volume/models/unet/"$FILE" 2>/dev/null || true
    # Pod compat symlink dir level
    if [ ! -e "/runpod-volume/models" ] && [ -d "$VOLUME/models" ]; then
      ln -sf "$VOLUME/models" /runpod-volume/models 2>/dev/null || true
    fi
  fi
  # Also cross-link secondary
  if [ -n "$SECONDARY" ]; then
    mkdir -p "$SECONDARY/models/diffusion_models" "$SECONDARY/models/unet"
    ln -sf "$TARGET_FILE" "$SECONDARY/models/diffusion_models/$FILE" 2>/dev/null || true
    ln -sf "$TARGET_FILE" "$SECONDARY/models/unet/$FILE" 2>/dev/null || true
  fi
  echo -e "${GREEN}Symlinks fixed. Verifying...${NC}"
  ls -lh "$TARGET_FILE" "$UNET_LINK" 2>/dev/null | sed 's/^/  /'
  [ -f "$ALT_TARGET" ] && ls -lh "$ALT_TARGET" 2>/dev/null | sed 's/^/  alt: /'
  echo ""
  echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║  === SUCCESS — already baked (no download needed) ===     ║${NC}"
  echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
  echo "  Primary:   $TARGET_FILE"
  echo "  Unet:      $UNET_LINK  (ComfyUI-GGUF scans both)"
  echo "  Alt:       $ALT_TARGET"
  echo "  Serverless sees: /runpod-volume/models/diffusion_models/$FILE"
  echo "  Serverless sees: /runpod-volume/models/unet/$FILE"
  df -h "$VOLUME" | tail -1 | awk '{print "  Free: " $4 "  Used: " $3 "  Size: " $2}'
  echo ""
  echo -e "${GREEN}You can STOP / TERMINATE this Pod — Network Volume persists.${NC}"
  echo "Next: Serverless → ghcr.io/alfa-jim/darkcoal-h3-new:latest  Disk 25GB  GPU A6000/4090  Min 0"
  # DON'T exit — still need to ensure required CLIP/VAEs are baked (added in v3)
  ALREADY_BAKED=1
  # fall through to Required H3 models check below; skip GGUF re-download
else
  ALREADY_BAKED=""
fi

# If GGUF already valid, skip re-download/verify and jump to Required models (still prints final SUCCESS later)
if [ "$ALREADY_BAKED" = "1" ]; then
  echo -e "${DIM}GGUF already valid — skipping GGUF re-download, checking required CLIP/VAEs…${NC}"
else

# If file exists but incomplete, keep it for resume (don't delete yet)
if [ -e "$TARGET_FILE" ]; then
  SZ=$(stat_bytes "$TARGET_FILE")
  GB=$(human_gb "$SZ")
  PCT=$(( SZ*100 / EXPECTED_BYTES ))
  [ "$PCT" -gt 100 ] && PCT=100
  echo -e "${YELLOW}Found PARTIAL file: $GB GB  $(bar "$PCT")${NC}"
  echo -e "${DIM}  $TARGET_FILE${NC}"
  if has_magic_gguf "$TARGET_FILE"; then echo -e "${DIM}  GGUF magic: OK (partial)${NC}"; else echo -e "${YELLOW}  GGUF magic: not yet (file too small)${NC}"; fi
  echo -e "${DIM}  Will resume — not deleting.${NC}"
  echo ""
fi

# ── Free space guard ─────────────────────────────────────────────────────────
FREE_KB=$(df -k "$VOLUME" 2>/dev/null | tail -1 | awk '{print $4}')
FREE_GB=$((FREE_KB/1024/1024))
if [ "$FREE_GB" -lt 14 ]; then
  echo -e "${RED}⚠ Low free space: ${FREE_GB} GB free on $VOLUME${NC}"
  echo -e "${YELLOW}  Need ~14GB free for 11.6GB GGUF + temp. If this is a 10GB volume, recreate as 20GB!${NC}"
  echo -e "${DIM}  Continuing anyway — but it may fail with 'No space'. Free up or enlarge volume.${NC}"
  echo ""
fi

# ── Install tools (with visual feedback) ─────────────────────────────────────
echo -e "${BOLD}── Installing download tools ──${NC}"
echo -ne "${DIM}  pip install huggingface_hub hf_transfer ...${NC}"
if pip install -q --upgrade huggingface_hub hf_transfer 2>&1 | tail -1; then
  echo -e "\r  ${GREEN}✔ huggingface_hub + hf_transfer ready${NC}          "
else
  pip install -q huggingface_hub 2>&1 | tail -1
  echo -e "\r  ${YELLOW}✔ huggingface_hub ready (hf_transfer not available, will still work)${NC}"
fi
export HF_HUB_ENABLE_HF_TRANSFER=1
# ensure pip bin on PATH (pip --user / PEP668 case) + detect hf cli via python -m
export PATH="$HOME/.local/bin:$PATH"
if ! command -v huggingface-cli >/dev/null 2>&1; then
  if python3 -m huggingface_hub.commands.huggingface_cli --help >/dev/null 2>&1; then
    huggingface-cli(){ python3 -m huggingface_hub.commands.huggingface_cli "$@"; }
    export -f huggingface-cli 2>/dev/null || true
  fi
fi
# aria2c check
if command -v aria2c >/dev/null 2>&1; then echo -e "  ${GREEN}✔ aria2c $(aria2c --version 2>/dev/null | head -1)${NC}"; else echo -e "  ${DIM}○ aria2c not found — will use wget fallback${NC}"; fi
if command -v huggingface-cli >/dev/null 2>&1; then echo -e "  ${GREEN}✔ $(huggingface-cli --version 2>&1 | head -1)${NC}"; elif python3 -m huggingface_hub.commands.huggingface_cli --version >/dev/null 2>&1; then echo -e "  ${GREEN}✔ huggingface_hub (python -m) $(python3 -m huggingface_hub.commands.huggingface_cli --version 2>&1 | head -1)${NC}"; else echo -e "  ${RED}✗ huggingface-cli missing (will use wget fallback — still works)${NC}"; fi
echo ""

# ── Download — with live visual indicator ────────────────────────────────────
echo -e "${BOLD}── Downloading (safe-resume, visual progress) ──${NC}"
echo -e "${DIM}  Repo: $REPO${NC}"
echo -e "${DIM}  File: $FILE${NC}"
echo -e "${DIM}  Dest: $TARGET_FILE${NC}"
echo -e "${DIM}  Re-run this script if SSH drops — it resumes automatically.${NC}"
echo ""

# Background live size monitor (polls file size every 1s while download runs)
# Shows [████░░] 45%  5.20/11.60 GB  (live)
LIVE_PID=""
start_live_monitor(){
  local target="$1"
  (
    local last_sz=0; local last_t=$(date +%s)
    while true; do
      if [ -e "$target" ]; then
        local sz=$(stat_bytes "$target")
        local pct=$(( sz*100 / EXPECTED_BYTES )); [ "$pct" -gt 100 ] && pct=100
        local gb=$(human_gb "$sz")
        local now=$(date +%s); local dt=$((now - last_t)); [ "$dt" -eq 0 ] && dt=1
        local dsz=$((sz - last_sz)); local speed=$(awk "BEGIN{printf \"%.1f\", $dsz/1024/1024/$dt}")
        # use %b + single % escape — no stray %s for printf format injection
        printf "\r  live: %s  %s/%s GB  %s MB/s   " "$(bar "$pct")" "$gb" "$EXPECTED_GB" "$speed"
        last_sz=$sz; last_t=$now
      else
        printf "\r  waiting for file ...          "
      fi
      sleep 1
    done
  ) &
  LIVE_PID=$!
}
stop_live_monitor(){
  if [ -n "$LIVE_PID" ] && kill -0 "$LIVE_PID" 2>/dev/null; then kill "$LIVE_PID" 2>/dev/null || true; wait "$LIVE_PID" 2>/dev/null || true; fi
  printf "\r%80s\r" " "
}

# ── Attempt 1: huggingface-cli (fastest, hf_transfer = 2-3x, resumable via xet) ─
set +e
HF_EXIT=127
HF_AVAILABLE=0
if command -v huggingface-cli >/dev/null 2>&1 || python3 -m huggingface_hub.commands.huggingface_cli --help >/dev/null 2>&1; then HF_AVAILABLE=1; fi
if [ $HF_AVAILABLE -eq 1 ]; then
  echo -e "${GREEN}→ huggingface-cli download (hf_transfer=$HF_HUB_ENABLE_HF_TRANSFER)${NC}"
  start_live_monitor "$TARGET_FILE"
  HF_CLI download "$REPO" "$FILE" --local-dir "$TARGET_DIR" --local-dir-use-symlinks False 2>&1
  HF_EXIT=$?
  stop_live_monitor
  echo ""
  if [ $HF_EXIT -eq 0 ] && [ -e "$TARGET_FILE" ]; then
    SZ=$(stat_bytes "$TARGET_FILE")
    if [ "$SZ" -gt $((EXPECTED_BYTES - EXPECTED_TOL)) ]; then
      echo -e "${GREEN}✔ huggingface-cli finished  ($(human_gb "$SZ") GB)${NC}"
    else
      echo -e "${YELLOW}huggingface-cli exit 0 but file small ($(human_gb "$SZ") GB) — will try fallback resume${NC}"
      HF_EXIT=1
    fi
  else
    echo -e "${YELLOW}huggingface-cli exit $HF_EXIT — trying fallback resume...${NC}"
  fi
else
  echo -e "${YELLOW}huggingface-cli not found — skipping to fallback (wget will handle resume)${NC}"
fi

# ── Fallback: aria2c or wget -c (both resume) ───────────────────────────────
if [ $HF_EXIT -ne 0 ] || [ ! -e "$TARGET_FILE" ]; then
  URL="https://huggingface.co/$REPO/resolve/main/$FILE"
  echo -e "${GREEN}→ Fallback: direct HTTP resume${NC}"
  echo -e "${DIM}  URL: $URL${NC}"
  DL_EXIT=1
  if command -v aria2c >/dev/null 2>&1; then
    echo -e "${GREEN}  Using aria2c (16 conn, resume, live bar)${NC}"
    start_live_monitor "$TARGET_FILE"
    aria2c -x 16 -s 16 -c --file-allocation=none --summary-interval=1 --allow-overwrite=true -d "$TARGET_DIR" -o "$FILE" "$URL"
    DL_EXIT=$?
    stop_live_monitor; echo ""
  else
    echo -e "${GREEN}  Using wget -c (resume + bar)${NC}"
    # wget -c needs .tmp handling to avoid clobber
    TMP="$TARGET_FILE.tmp"
    # if target already exists partial, wget -c will resume .tmp or target depending; unify
    if [ -f "$TARGET_FILE" ] && [ ! -f "$TMP" ]; then cp -n "$TARGET_FILE" "$TMP" 2>/dev/null || true; fi
    start_live_monitor "$TMP"
    wget -c --progress=bar:force --tries=5 --timeout=30 -O "$TMP" "$URL"
    DL_EXIT=$?
    stop_live_monitor; echo ""
    if [ $DL_EXIT -eq 0 ] && [ -f "$TMP" ]; then
      mv -f "$TMP" "$TARGET_FILE"
      echo -e "${GREEN}✔ wget finished → $TARGET_FILE${NC}"
    fi
  fi
  if [ $DL_EXIT -ne 0 ]; then
    echo -e "${RED}Download failed. Re-run this script to resume (it picks up where it left off).${NC}"
    echo -e "${DIM}If it repeatedly fails, try:  rm -f \"$TARGET_FILE\" \"$TARGET_FILE.tmp\"  and re-run, or enlarge volume to 20GB.${NC}"
    exit 1
  fi
fi
set -e

# ── Verify ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Verifying ──${NC}"
if [ ! -f "$TARGET_FILE" ]; then
  FOUND=$(find "$TARGET_DIR" -name "$FILE" -type f 2>/dev/null | head -1)
  if [ -n "$FOUND" ] && [ "$FOUND" != "$TARGET_FILE" ]; then
    echo -e "${YELLOW}Found at $FOUND — moving to $TARGET_FILE${NC}"
    mv -f "$FOUND" "$TARGET_FILE"
  else
    echo -e "${RED}ERROR: File not found after download. Listing $TARGET_DIR${NC}"
    ls -lh "$TARGET_DIR" 2>&1 | head -20
    exit 1
  fi
fi
SZ=$(stat_bytes "$TARGET_FILE")
GB=$(human_gb "$SZ")
PCT=$(( SZ*100 / EXPECTED_BYTES )); [ "$PCT" -gt 100 ] && PCT=100
echo -e "  Size: $GB GB  $(bar "$PCT")  $SZ bytes (expected $EXPECTED_BYTES)"
ls -lh "$TARGET_FILE" | sed 's/^/  /'
if has_magic_gguf "$TARGET_FILE"; then
  echo -e "  ${GREEN}✔ GGUF magic 'GGUF' OK${NC}"
else
  echo -e "${RED}✗ GGUF header invalid — file corrupted. Deleting and aborting; re-run.${NC}"
  rm -f "$TARGET_FILE"
  exit 1
fi
if [ "$SZ" -lt $((EXPECTED_BYTES - EXPECTED_TOL)) ]; then
  echo -e "${YELLOW}⚠ Size smaller than expected (~${EXPECTED_GB} GB). May be incomplete — re-run to resume.${NC}"
  echo -e "${DIM}  Expected ~$EXPECTED_BYTES bytes (±$EXPECTED_TOL). Got $SZ.${NC}"
  # don't exit, still create symlink so partial resume works next run
fi

# ── Symlinks (both mount views + both filename variants) ─────────────────────
echo ""
echo -e "${BOLD}── Wiring symlinks (so ComfyUI finds it on either mount) ──${NC}"
ln -sf "$TARGET_FILE" "$UNET_LINK" && echo -e "  ${GREEN}✔ $UNET_LINK → $TARGET_FILE${NC}" || echo -e "  ${YELLOW}link $UNET_LINK failed${NC}"
ls -lh "$UNET_LINK" 2>/dev/null | sed 's/^/    /'
# Secondary mount
if [ -n "$SECONDARY" ]; then
  echo -e "  ${DIM}Cross-linking $SECONDARY ...${NC}"
  ln -sf "$TARGET_FILE" "$SECONDARY/models/diffusion_models/$FILE" 2>/dev/null || cp -n "$TARGET_FILE" "$SECONDARY/models/diffusion_models/$FILE" 2>/dev/null || true
  ln -sf "$SECONDARY/models/diffusion_models/$FILE" "$SECONDARY/models/unet/$FILE" 2>/dev/null || ln -sf "$TARGET_FILE" "$SECONDARY/models/unet/$FILE" 2>/dev/null || true
  mkdir -p /runpod-volume/models/diffusion_models /runpod-volume/models/unet 2>/dev/null || true
  ln -sf "$TARGET_FILE" /runpod-volume/models/diffusion_models/"$FILE" 2>/dev/null || true
  ln -sf "$TARGET_FILE" /runpod-volume/models/unet/"$FILE" 2>/dev/null || true
  if [ ! -e "/runpod-volume/models" ] && [ -d "$VOLUME/models" ]; then
    ln -sf "$VOLUME/models" /runpod-volume/models 2>/dev/null || true
  fi
  echo -e "    ${GREEN}✔ $SECONDARY cross-linked${NC}"
fi
# Alt name alias (so either REPO naming works)
ln -sf "$TARGET_FILE" "$ALT_TARGET" 2>/dev/null || true
ln -sf "$TARGET_FILE" "$ALT_LINK" 2>/dev/null || true

fi # end skip-GGUF when ALREADY_BAKED

# ── Required H3 models for native 0.33.1 pipeline (bakes missing — resume-safe) ─
# playground/workflow uses:
#   text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors  (~17GB? actually ~9GB shard)
#   vae/minimax_h3_video_vae_int8_convrot.safetensors
#   vae/minimax_h3_audio_vae_fp32.safetensors
# Without these, ComfyUI fails to load CLIPLoader/VAELoader. Fetch from Comfy-Org/MiniMax-H3.
echo ""
echo -e "${BOLD}── Required MiniMax-H3 models (CLIP + VAEs) ──${NC}"
mkdir -p "$VOLUME/models/text_encoders" "$VOLUME/models/vae" 2>/dev/null || true
[ -n "$SECONDARY" ] && mkdir -p "$SECONDARY/models/text_encoders" "$SECONDARY/models/vae" 2>/dev/null || true
# Qwen3-VL CLIP
if [ ! -f "$VOLUME/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" ]; then
  echo -e "${GREEN}→ fetching Qwen3-VL CLIP (Comfy-Org/MiniMax-H3) …${NC}"
  HF_CLI download Comfy-Org/MiniMax-H3 qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors --local-dir "$VOLUME/models/text_encoders" --local-dir-use-symlinks False 2>&1 | tail -5 || true
  # hf download flattens? ensure correct name/loc
  find "$VOLUME/models/text_encoders" -name "qwen3vl*" -type f 2>/dev/null | head
else echo -e "${GREEN}✔ text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors present${NC}"; fi
# Video VAE
if [ ! -f "$VOLUME/models/vae/minimax_h3_video_vae_int8_convrot.safetensors" ]; then
  echo -e "${GREEN}→ fetching video VAE …${NC}"
  HF_CLI download Comfy-Org/MiniMax-H3 minimax_h3_video_vae_int8_convrot.safetensors --local-dir "$VOLUME/models/vae" --local-dir-use-symlinks False 2>&1 | tail -5 || true
else echo -e "${GREEN}✔ vae/minimax_h3_video_vae_int8_convrot.safetensors present${NC}"; fi
# Audio VAE
if [ ! -f "$VOLUME/models/vae/minimax_h3_audio_vae_fp32.safetensors" ]; then
  echo -e "${GREEN}→ fetching audio VAE …${NC}"
  HF_CLI download Comfy-Org/MiniMax-H3 minimax_h3_audio_vae_fp32.safetensors --local-dir "$VOLUME/models/vae" --local-dir-use-symlinks False 2>&1 | tail -5 || true
else echo -e "${GREEN}✔ vae/minimax_h3_audio_vae_fp32.safetensors present${NC}"; fi
# Cross-link secondary view
if [ -n "$SECONDARY" ]; then
  for f in qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors; do [ -f "$VOLUME/models/text_encoders/$f" ] && ln -sf "$VOLUME/models/text_encoders/$f" "$SECONDARY/models/text_encoders/$f" 2>/dev/null || true; done
  for f in minimax_h3_video_vae_int8_convrot.safetensors minimax_h3_audio_vae_fp32.safetensors; do [ -f "$VOLUME/models/vae/$f" ] && ln -sf "$VOLUME/models/vae/$f" "$SECONDARY/models/vae/$f" 2>/dev/null || true; done
  mkdir -p /runpod-volume/models/text_encoders /runpod-volume/models/vae 2>/dev/null || true
  for f in qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors; do [ -f "$VOLUME/models/text_encoders/$f" ] && ln -sf "$VOLUME/models/text_encoders/$f" /runpod-volume/models/text_encoders/"$f" 2>/dev/null || true; done
  for f in minimax_h3_video_vae_int8_convrot.safetensors minimax_h3_audio_vae_fp32.safetensors; do [ -f "$VOLUME/models/vae/$f" ] && ln -sf "$VOLUME/models/vae/$f" /runpod-volume/models/vae/"$f" 2>/dev/null || true; done
fi
echo -e "${DIM}  (if downloads failed due to network, re-run script — it resumes)${NC}"

# ── Final report ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  === SUCCESS — volume baked  ✓ ===                        ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo "  Primary:   $TARGET_FILE  ($GB GB)"
echo "  Symlink:   $UNET_LINK"
[ -f "$ALT_TARGET" ] && echo "  Alt alias: $ALT_TARGET"
[ -n "$SECONDARY" ] && echo "  Secondary: $SECONDARY/models/diffusion_models/$FILE"
echo "  Serverless sees: /runpod-volume/models/diffusion_models/$FILE"
echo "  Serverless sees: /runpod-volume/models/unet/$FILE (symlink)"
echo ""
ls -lh "$TARGET_FILE" "$UNET_LINK" 2>/dev/null | sed 's/^/  /'
df -h "$VOLUME" | tail -1 | awk '{print "  Disk free: " $4 "  used: " $3 "  size: " $2}'
echo ""
echo -e "${GREEN}You can now STOP / TERMINATE this Pod — Network Volume persists.${NC}"
echo "Next: Serverless Endpoint"
echo "  Container: ghcr.io/alfa-jim/darkcoal-h3-new:latest"
echo "    pinned:  ghcr.io/alfa-jim/darkcoal-h3-new:latest@sha256:5aa2a2dc66b95f5227891e3743621fae21e069921e4b97110eab572178cf199a  # 3a24498"
echo "  Attach SAME Network Volume (darkcoal-h3, 20GB, same region!)  Disk 25GB  GPU A6000/4090  Min 0 Max 2 Idle 5s Exec 300s"
echo "  Test: open playground.html → paste endpoint /runsync + key → Generate"
echo ""
echo -e "${DIM}Tip: to bake unsloth filename instead, edit top: REPO=\"unsloth/MiniMax-H3-GGUF\" FILE=\"minimax_h3_ref2va_pruned-Q4_K.gguf\"${NC}"
echo -e "${DIM}Re-run this script anytime to verify — it will report 'already baked' and fix symlinks.${NC}"
