#!/usr/bin/env bash
# POD_BAKE_ONLY.sh — bake ONLY correct H3 files (wget, no huggingface-cli, H3-only)
# Abiray RELIGION: MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf 11.6G + qwen3vl_nvfp4_awq + 2 vaes
# Usage: curl -sSL https://raw.githubusercontent.com/Alfa-jim/darkcoal-h3-new/main/POD_BAKE_ONLY.sh | bash
set -e
VOL=$([ -d /workspace ] && echo /workspace || echo /runpod-volume)
echo ">>> VOL=$VOL $(df -h $VOL 2>/dev/null | tail -1)"
mkdir -p $VOL/models/diffusion_models $VOL/models/text_encoders $VOL/models/vae $VOL/models/unet
echo ">>> WGET Abiray Q4_K_M 11.6G..."
wget -c --progress=bar:force -O $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf https://huggingface.co/Abiray/MiniMax-H3-Pruned-GGUF/resolve/main/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf
echo ">>> WGET CLIP qwen3vl_nvfp4..."
wget -c --progress=bar:force -O $VOL/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors || wget -c --progress=bar:force -O $VOL/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors
echo ">>> WGET video VAE int8..."
wget -c --progress=bar:force -O $VOL/models/vae/minimax_h3_video_vae_int8_convrot.safetensors https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_video_vae_int8_convrot.safetensors || wget -c --progress=bar:force -O $VOL/models/vae/minimax_h3_video_vae_int8_convrot.safetensors https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/minimax_h3_video_vae_int8_convrot.safetensors
echo ">>> WGET audio VAE..."
wget -c --progress=bar:force -O $VOL/models/vae/minimax_h3_audio_vae_fp32.safetensors https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_audio_vae_fp32.safetensors || wget -c --progress=bar:force -O $VOL/models/vae/minimax_h3_audio_vae_fp32.safetensors https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/minimax_h3_audio_vae_fp32.safetensors
ln -sf $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf $VOL/models/unet/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf
mkdir -p /runpod-volume/models/diffusion_models /runpod-volume/models/unet /runpod-volume/models/text_encoders /runpod-volume/models/vae 2>/dev/null || true
ln -sf $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf /runpod-volume/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf 2>/dev/null || true
ln -sf $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf /runpod-volume/models/unet/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf 2>/dev/null || true
[ -f $VOL/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors ] && ln -sf $VOL/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors /runpod-volume/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors 2>/dev/null || true
for f in minimax_h3_video_vae_int8_convrot.safetensors minimax_h3_audio_vae_fp32.safetensors; do [ -f $VOL/models/vae/$f ] && ln -sf $VOL/models/vae/$f /runpod-volume/models/vae/$f 2>/dev/null || true; done
echo ">>> DONE verify:"
ls -lh $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf $VOL/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors $VOL/models/vae/minimax_h3* 2>/dev/null | sed 's/^/  /'
head -c 4 $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf | grep -q GGUF && echo "  ✔ GGUF magic OK (11.6G)" || echo "  ✗ GGUF BAD"
df -h $VOL 2>/dev/null | tail -1 | awk '{print "  Disk free: "$4" used: "$3" size: "$2}'
