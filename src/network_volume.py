"""
darkcoal-h3-new — network volume diagnostics
Enabled with NETWORK_VOLUME_DEBUG=true
"""
import os

MODEL_DIRS = {
    "diffusion_models": [".gguf"],
    "unet": [".gguf"],
    "checkpoints": [".safetensors", ".ckpt"],
    "vae": [".safetensors"],
}

def is_network_volume_debug_enabled() -> bool:
    return os.environ.get("NETWORK_VOLUME_DEBUG", "false").lower() == "true"

def run_network_volume_diagnostics() -> None:
    print("=" * 72)
    print("NETWORK VOLUME DIAGNOSTICS  NETWORK_VOLUME_DEBUG=true")
    print("=" * 72)
    cfg = "/comfyui/extra_model_paths.yaml"
    print(f"\n[1] {cfg}")
    if os.path.isfile(cfg):
        print("  ✓ found")
        print(open(cfg).read())
    else:
        print("  ✗ missing — ComfyUI won't see /runpod-volume")

    vol = "/runpod-volume"
    print(f"\n[2] volume mount {vol}  exists={os.path.isdir(vol)}")
    if not os.path.isdir(vol):
        print("  ✗ not mounted — attach Network Volume to endpoint!")
        return

    models = os.path.join(vol, "models")
    print(f"\n[3] {models}  exists={os.path.isdir(models)}")
    if not os.path.isdir(models):
        print("  ✗ missing — create /runpod-volume/models/diffusion_models/")
        return

    # list
    for sub, exts in MODEL_DIRS.items():
        p = os.path.join(models, sub)
        print(f"\n  {sub}/")
        if not os.path.isdir(p):
            print("    (no dir)")
            continue
        files = os.listdir(p)
        if not files:
            print("    (empty)")
            continue
        for f in files:
            fp = os.path.join(p, f)
            if os.path.isfile(fp):
                sz = os.path.getsize(fp)
                gb = sz / (1024**3)
                mark = "✓" if any(f.lower().endswith(e) for e in exts) else "?"
                print(f"    {mark} {f}  {gb:.2f} GB")
    print("\n[done] expect: /runpod-volume/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf ~11.6GB")
    print("  also /runpod-volume/models/unet/ symlink -> same file (UnetLoaderGGUF scans both)")
    print("=" * 72)

def fmt_size(b: int) -> str:
    for u in ["B","KB","MB","GB"]:
        if b < 1024: return f"{b:.1f}{u}"
        b/=1024
    return f"{b:.1f}TB"
