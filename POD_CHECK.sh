#!/usr/bin/env bash
# POD_CHECK.sh — short check for H3 manage: correct 4 files + no junk + GGUF magic
# Usage: curl -sSL https://raw.githubusercontent.com/Alfa-jim/darkcoal-h3-new/main/POD_CHECK.sh | bash
VOL=$([ -d /workspace ] && echo /workspace || echo /runpod-volume)
echo ">>> VOL=$VOL $(df -h $VOL 2>/dev/null | tail -1)"
echo ">>> CHECK correct files:"
for p in "$VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf" "$VOL/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" "$VOL/models/vae/minimax_h3_video_vae_int8_convrot.safetensors" "$VOL/models/vae/minimax_h3_audio_vae_fp32.safetensors"; do [ -e "$p" ] && ls -lh "$p" | awk '{print "  ✔ "$9" "$5}' || echo "  ✗ MISSING $p"; done
F="$VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf"; [ -L "$F" ] && echo "  ✗ SYMLINK (bad, should be real 11.6G file)" || { [ -f "$F" ] && head -c 4 "$F" | grep -q GGUF && echo "  ✔ GGUF magic OK" || echo "  ✗ GGUF BAD/missing"; }
[ -e "$VOL/models/unet/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf" ] && echo "  ✔ unet symlink OK" || echo "  ○ unet symlink missing (will be created by bake)"
echo ">>> CHECK junk (should be empty):"
ls $VOL/models/diffusion_models/minimax_h3_ref2va_pruned_fp8* $VOL/models/diffusion_models/MiniMax-H3-FL2VA* $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q2* $VOL/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q5* $VOL/models/diffusion_models/minimax_h3_ref2va_pruned-Q4_K.gguf 2>/dev/null | sed 's/^/  ✗ JUNK /' || echo "  ✔ no junk"
echo ">>> DF:"; df -h $VOL 2>/dev/null | tail -1 | awk '{print "  free "$4" used "$3" size "$2}'
