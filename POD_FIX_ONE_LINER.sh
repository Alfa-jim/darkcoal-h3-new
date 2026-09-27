#!/usr/bin/env bash
# POD_FIX_ONE_LINER.sh — CLEAN useless H3 ONLY (never touches other models) + BAKE correct Abiray — wget only, no huggingface-cli
# SAFETY GUARANTEE: every rm is an explicit H3 filename pattern (minimax_h3 / MiniMax-H3 / qwen3vl_32b_minimax_h3). No wildcards outside H3, no rm -rf.
# Other volume content (qwen-rapid-nsfw, flux, sdxl, etc) is NEVER matched and NEVER deleted.
# Abiray RELIGION: https://huggingface.co/Abiray/MiniMax-H3-Pruned-GGUF
#   CORRECT (touched only in this script): MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf 11.6G + qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors + minimax_h3_video_vae_int8_convrot.safetensors + minimax_h3_audio_vae_fp32.safetensors
#   USELESS (explicitly removed): fp8 19.5G (OOM 24GB), FL2VA, Q2/Q3/Q5/Q6/Q8 quants, unsloth Q4 dup, Q4_K_M LLM 17G, and ONLY their .tmp/.part resume files
# Usage:
#   curl -sSL https://raw.githubusercontent.com/Alfa-jim/darkcoal-h3-new/main/POD_FIX_ONE_LINER.sh | bash
set -e
VOL=$([ -d /workspace ] && echo /workspace || echo /runpod-volume)
echo ">>> VOL=$VOL $(df -h $VOL 2>/dev/null | tail -1)"
echo ">>> SAFETY — inventory (other models are ignored, not deleted):"
ls -lh $VOL/models/diffusion_models/MiniMax* $VOL/models/diffusion_models/minimax* $VOL/models/unet/MiniMax* $VOL/models/unet/minimax* 2>/dev/null | sed 's/^/  H3 before: /' || echo "  (no H3 yet)"
echo ">>> CLEAN — deleting ONLY useless H3 files (explicit patterns):"
# diffusion_models — fp8 + FL2VA + wrong quants + unsloth dup + ONLY H3 tmp/part
rm -fv $VOL/models/diffusion_models/minimax_h3_ref2va_pruned_fp8_scaled.safetensors $VOL/models/diffusion_models/minimax_h3_ref2va_pruned_fp8* $VOL/models/diffusion_models/MiniMax-H3-FL2VA* $VOL/models/diffusion_models/minimax_h3_fl2va* $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q2*.gguf $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q3*.gguf $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q5*.gguf $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q6*.gguf $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q8*.gguf $VOL/models/diffusion_models/minimax_h3_ref2va_pruned-Q4_K.gguf $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf.tmp $VOL/models/diffusion_models/minimax_h3_ref2va_pruned-Q4_K.gguf.tmp $VOL/models/diffusion_models/MiniMax-H3*.part $VOL/models/diffusion_models/minimax_h3*.part 2>/dev/null || true
# unet — same H3 only
rm -fv $VOL/models/unet/minimax_h3_ref2va_pruned_fp8* $VOL/models/unet/MiniMax-H3-FL2VA* $VOL/models/unet/minimax_h3_fl2va* $VOL/models/unet/MiniMax-H3-Ref2VA-Pruned-Q2*.gguf $VOL/models/unet/MiniMax-H3-Ref2VA-Pruned-Q3*.gguf $VOL/models/unet/MiniMax-H3-Ref2VA-Pruned-Q5*.gguf $VOL/models/unet/MiniMax-H3-Ref2VA-Pruned-Q6*.gguf $VOL/models/unet/MiniMax-H3-Ref2VA-Pruned-Q8*.gguf $VOL/models/unet/minimax_h3_ref2va_pruned-Q4_K.gguf 2>/dev/null || true
# text_encoders — ONLY the oversized Q4_K_M LLM for sd-cli (17G, not needed for ComfyUI), keep Q2/others untouched
rm -fv $VOL/models/text_encoders/qwen3vl_32b_minimax_h3-Q4_K_M.gguf $VOL/models/text_encoders/qwen3vl_32b_minimax_h3-Q4_K_M.gguf.tmp $VOL/models/text_encoders/qwen3vl_32b_minimax_h3-Q4_K_M.gguf.part 2>/dev/null || true
echo ">>> cleaned — free now $(df -h $VOL 2>/dev/null | tail -1)"
mkdir -p $VOL/models/diffusion_models $VOL/models/text_encoders $VOL/models/vae $VOL/models/unet
echo ">>> WGET Abiray Q4_K_M 11.6G (correct)..."
wget -c --progress=bar:force -O $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf https://huggingface.co/Abiray/MiniMax-H3-Pruned-GGUF/resolve/main/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf
echo ">>> WGET CLIP qwen3vl_nvfp4 (correct)..."
wget -c --progress=bar:force -O $VOL/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors || wget -c --progress=bar:force -O $VOL/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors
echo ">>> WGET video VAE int8 (correct)..."
wget -c --progress=bar:force -O $VOL/models/vae/minimax_h3_video_vae_int8_convrot.safetensors https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_video_vae_int8_convrot.safetensors || wget -c --progress=bar:force -O $VOL/models/vae/minimax_h3_video_vae_int8_convrot.safetensors https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/minimax_h3_video_vae_int8_convrot.safetensors
echo ">>> WGET audio VAE (correct)..."
wget -c --progress=bar:force -O $VOL/models/vae/minimax_h3_audio_vae_fp32.safetensors https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_audio_vae_fp32.safetensors || wget -c --progress=bar:force -O $VOL/models/vae/minimax_h3_audio_vae_fp32.safetensors https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/minimax_h3_audio_vae_fp32.safetensors
ln -sf $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf $VOL/models/unet/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf
mkdir -p /runpod-volume/models/diffusion_models /runpod-volume/models/unet /runpod-volume/models/text_encoders /runpod-volume/models/vae 2>/dev/null || true
ln -sf $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf /runpod-volume/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf 2>/dev/null || true
ln -sf $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf /runpod-volume/models/unet/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf 2>/dev/null || true
[ -f $VOL/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors ] && ln -sf $VOL/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors /runpod-volume/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors 2>/dev/null || true
for f in minimax_h3_video_vae_int8_convrot.safetensors minimax_h3_audio_vae_fp32.safetensors; do [ -f $VOL/models/vae/$f ] && ln -sf $VOL/models/vae/$f /runpod-volume/models/vae/$f 2>/dev/null || true; done
echo ">>> DONE verify (only H3 listed, other models untouched):"
ls -lh $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf $VOL/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors $VOL/models/vae/minimax_h3* 2>/dev/null | sed 's/^/  /'
head -c 4 $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf | grep -q GGUF && echo "  ✔ GGUF magic OK" || echo "  ✗ GGUF BAD"
df -h $VOL 2>/dev/null | tail -1 | awk '{print "  Disk free: "$4" used: "$3" size: "$2}'
echo ">>> STOP Pod — volume persists. Serverless: ghcr.io/alfa-jim/darkcoal-h3-new:latest Disk 25GB GPU 24GB"
