#!/usr/bin/env bash
set -e

# ── SSH (optional) ──
if [ -n "$PUBLIC_KEY" ]; then
  mkdir -p ~/.ssh && echo "$PUBLIC_KEY" > ~/.ssh/authorized_keys
  chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys
  for k in rsa ecdsa ed25519; do
    f="/etc/ssh/ssh_host_${k}_key"
    [ -f "$f" ] || ssh-keygen -t "$k" -f "$f" -q -N ''
  done
  service ssh start && echo "[h3] SSH started" || echo "[h3] SSH failed" >&2
fi

# ── tcmalloc ──
TCMALLOC="$(ldconfig -p 2>/dev/null | grep -Po 'libtcmalloc\.so\.\d' | head -n1 || true)"
[ -n "$TCMALLOC" ] && export LD_PRELOAD="$TCMALLOC"

# ── GPU check ──
echo "[h3] Checking GPU..."
if ! GPU_MSG=$(python3 -c "
import torch
try:
    torch.cuda.init()
    n=torch.cuda.get_device_name(0); cap=torch.cuda.get_device_capability(0)
    _=(torch.zeros(8,device='cuda')+1).sum().item(); torch.cuda.synchronize()
    print(f'OK {n} sm_{cap[0]}{cap[1]} torch{torch.__version__} cuda{torch.version.cuda}')
except Exception as e:
    print(f'FAIL {e}'); exit(1)
" 2>&1); then
  echo "[h3] GPU check failed: $GPU_MSG"; exit 1
fi
echo "[h3] GPU $GPU_MSG"

# ── ComfyUI-Manager offline ──
comfy-manager-set-mode offline 2>/dev/null || true

# ── Pod compat: Pod volume at /workspace, Serverless at /runpod-volume  ──
# User instruction: POD bakes into /workspace, Serverless reads /runpod-volume
# So we symlink /workspace/models -> /runpod-volume/models if needed
if [ ! -d /runpod-volume/models ] && [ -d /workspace/models ]; then
  echo "[h3] Pod compat: linking /workspace/models -> /runpod-volume/models" >&2
  mkdir -p /runpod-volume
  for d in /workspace/models/*; do
    [ -e "$d" ] || continue
    bn=$(basename "$d")
    [ -e "/runpod-volume/models/$bn" ] || ln -s "$d" "/runpod-volume/models/$bn" 2>/dev/null || true
  done
  [ -e /runpod-volume/models ] || ln -s /workspace/models /runpod-volume/models 2>/dev/null || true
fi
mkdir -p /runpod-volume/models/diffusion_models /runpod-volume/models/unet

# ── Show GGUF status ──
GGUF_PRUNED="/runpod-volume/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf"
GGUF_UNSLOTH="/runpod-volume/models/diffusion_models/minimax_h3_ref2va_pruned-Q4_K.gguf"
echo "[h3] Checking GGUF..."
if [ -f "$GGUF_PRUNED" ]; then
  echo "  ✓ $GGUF_PRUNED ($(du -h "$GGUF_PRUNED" | cut -f1))"
elif [ -f "$GGUF_UNSLOTH" ]; then
  echo "  ✓ $GGUF_UNSLOTH ($(du -h "$GGUF_UNSLOTH" | cut -f1))"
else
  echo "  ✗ NOT FOUND — expected one of:"
  echo "      $GGUF_PRUNED  (Abiray Q4_K_M 11.6GB)"
  echo "      $GGUF_UNSLOTH  (unsloth Q4_K)"
  echo "    Run POD_BAKE_COMMAND.sh on a Pod with the same Network Volume attached!"
  if [ -f "/runpod-volume/models/unet/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf" ]; then
    echo "  ✓ fallback /runpod-volume/models/unet/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf"
  fi
  ls -lh /runpod-volume/models/diffusion_models/ 2>&1 | head -20 || true
fi

echo "[h3] Starting ComfyUI..."
: "${COMFY_LOG_LEVEL:=DEBUG}"
PIDFILE="/tmp/comfyui.pid"

if [ "$SERVE_API_LOCALLY" = "true" ]; then
  python -u /comfyui/main.py --disable-auto-launch --disable-metadata --listen --verbose "${COMFY_LOG_LEVEL}" --log-stdout &
  echo $! > "$PIDFILE"
  echo "[h3] RunPod handler (local API)..."
  python -u /handler.py --rp_serve_api --rp_api_host=0.0.0.0
else
  python -u /comfyui/main.py --disable-auto-launch --disable-metadata --verbose "${COMFY_LOG_LEVEL}" --log-stdout &
  echo $! > "$PIDFILE"
  echo "[h3] RunPod handler..."
  python -u /handler.py
fi
