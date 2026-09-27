#!/usr/bin/env bash
# POD_CLEAN_ONLY.sh — delete ONLY unused H3 files (H3-only surgical, other models untouched)
# Deletes: fp8 19.5G, FL2VA, Q2/Q3/Q5/Q6/Q8, unsloth Q4 dup, Q4_K_M LLM 17G, and ONLY H3 .tmp/.part
# Keeps: MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf 11.6G, qwen3vl_nvfp4_awq, video_vae int8, audio_vae
# Usage: curl -sSL https://raw.githubusercontent.com/Alfa-jim/darkcoal-h3-new/main/POD_CLEAN_ONLY.sh | bash
set -e
VOL=$([ -d /workspace ] && echo /workspace || echo /runpod-volume)
echo ">>> VOL=$VOL $(df -h $VOL 2>/dev/null | tail -1)"
echo ">>> H3 before:"
ls -lh $VOL/models/diffusion_models/*H3* $VOL/models/diffusion_models/*h3* $VOL/models/unet/*H3* 2>/dev/null | sed 's/^/  /' || echo "  (no H3)"
echo ">>> CLEAN unused H3 only..."
rm -fv $VOL/models/diffusion_models/minimax_h3_ref2va_pruned_fp8* $VOL/models/diffusion_models/MiniMax-H3-FL2VA* $VOL/models/diffusion_models/minimax_h3_fl2va* $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q2*.gguf $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q3*.gguf $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q5*.gguf $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q6*.gguf $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q8*.gguf $VOL/models/diffusion_models/minimax_h3_ref2va_pruned-Q4_K.gguf $VOL/models/diffusion_models/MiniMax-H3*.tmp $VOL/models/diffusion_models/minimax_h3*.part 2>/dev/null || true
rm -fv $VOL/models/unet/minimax_h3_ref2va_pruned_fp8* $VOL/models/unet/MiniMax-H3-FL2VA* $VOL/models/unet/minimax_h3_fl2va* $VOL/models/unet/MiniMax-H3-Ref2VA-Pruned-Q2*.gguf $VOL/models/unet/MiniMax-H3-Ref2VA-Pruned-Q3*.gguf $VOL/models/unet/MiniMax-H3-Ref2VA-Pruned-Q5*.gguf $VOL/models/unet/MiniMax-H3-Ref2VA-Pruned-Q6*.gguf $VOL/models/unet/MiniMax-H3-Ref2VA-Pruned-Q8*.gguf $VOL/models/unet/minimax_h3_ref2va_pruned-Q4_K.gguf 2>/dev/null || true
[ -L $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf ] && rm -fv $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf || true
[ -L $VOL/models/unet/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf ] && rm -fv $VOL/models/unet/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf || true
rm -fv $VOL/models/text_encoders/qwen3vl_32b_minimax_h3-Q4_K_M.gguf $VOL/models/text_encoders/qwen3vl_32b_minimax_h3-Q4_K_M.gguf.tmp $VOL/models/text_encoders/qwen3vl_32b_minimax_h3-Q4_K_M.gguf.part 2>/dev/null || true
echo ">>> H3 after:"
ls -lh $VOL/models/diffusion_models/MiniMax* $VOL/models/diffusion_models/minimax* $VOL/models/unet/MiniMax* 2>/dev/null | sed 's/^/  /' || echo "  (diffusion cleaned)"
ls -lh $VOL/models/text_encoders/qwen3vl* $VOL/models/vae/minimax* 2>/dev/null | sed 's/^/  kept: /' || true
df -h $VOL 2>/dev/null | tail -1 | awk '{print "  Disk free: "$4" used: "$3" size: "$2}'
echo ">>> CLEAN done — now run bake:"
echo "curl -sSL https://raw.githubusercontent.com/Alfa-jim/darkcoal-h3-new/main/POD_BAKE_ONLY.sh | bash"
