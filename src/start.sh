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

# ── Network Volume dirs (sd-cli only) ──
mkdir -p /runpod-volume/models/diffusion_models /runpod-volume/models/text_encoders /runpod-volume/models/vae
mkdir -p /workspace/models/diffusion_models /workspace/models/text_encoders /workspace/models/vae
if [ ! -d /runpod-volume/models ] && [ -d /workspace/models ]; then
  echo "[h3] Pod compat: linking /workspace/models -> /runpod-volume/models" >&2
  mkdir -p /runpod-volume
  for d in /workspace/models/*; do
    [ -e "$d" ] || continue
    bn=$(basename "$d")
    [ -e "/runpod-volume/models/$bn" ] || ln -s "$d" "/runpod-volume/models/$bn" 2>/dev/null || true
  done
fi
echo "[h3] Network Volume dirs ready:"
ls -ld /runpod-volume/models/diffusion_models /runpod-volume/models/text_encoders /runpod-volume/models/vae 2>&1 | sed 's/^/  /'

# ── Show GGUF status ──
echo "[h3] Checking GGUF..."
for p in /runpod-volume/models/diffusion_models/minimax_h3_ref2va_pruned-Q4_K.gguf /workspace/models/diffusion_models/minimax_h3_ref2va_pruned-Q4_K.gguf /runpod-volume/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf; do [ -f "$p" ] && echo "  ✓ diffusion $p ($(du -h "$p"|cut -f1))" && break; done
for p in /runpod-volume/models/text_encoders/qwen3vl_32b_minimax_h3-Q2_K_M.gguf /workspace/models/text_encoders/qwen3vl_32b_minimax_h3-Q2_K_M.gguf; do [ -f "$p" ] && echo "  ✓ llm Q2 $p ($(du -h "$p"|cut -f1))" && break; done
for p in /runpod-volume/models/vae/minimax_h3_video_vae_fp16.safetensors /runpod-volume/models/vae/minimax_h3_video_vae_int8_convrot.safetensors; do [ -f "$p" ] && echo "  ✓ vae $p ($(du -h "$p"|cut -f1))" && break; done
ls -lh /runpod-volume/models/diffusion_models/ /runpod-volume/models/text_encoders/ 2>&1 | head -20 || true
echo "[h3] sd-cli $(/usr/local/bin/sd-cli --help 2>&1 | head -1 || echo 'binary ready')"

# ── sd-cli ONLY — no ComfyUI (saves 2-3G VRAM, 60s boot) ──
if [ "$SERVE_API_LOCALLY" = "true" ]; then
  echo "[h3] RunPod handler (local API, sd-cli only)..."
  python -u /handler.py --rp_serve_api --rp_api_host=0.0.0.0
else
  echo "[h3] RunPod handler (sd-cli only)..."
  python -u /handler.py
fi
