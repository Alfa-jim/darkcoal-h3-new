"""
darkcoal-h3-new — RunPod Serverless handler for MiniMax H3 (sd-cli ONLY, no ComfyUI)
unsloth/MiniMax-H3-GGUF Q4 11G + Qwen Q2 12G — fits 24GB with --offload-to-cpu --backend te=cpu
"""
import base64, json, os, subprocess, tempfile, time, shlex
import runpod
from runpod.serverless.utils import rp_upload
try:
    from src.network_volume import is_network_volume_debug_enabled, run_network_volume_diagnostics
except ImportError:
    try:
        from network_volume import is_network_volume_debug_enabled, run_network_volume_diagnostics
    except ImportError:
        def is_network_volume_debug_enabled(): return False
        def run_network_volume_diagnostics(): return None

# sd-cli paths — Pod /workspace == Serverless /runpod-volume (same volume)
CANDIDATE_BASES = ["/runpod-volume", "/workspace"]
def _find(p):
    for b in CANDIDATE_BASES:
        fp = os.path.join(b, p)
        if os.path.exists(fp):
            return fp
    return os.path.join(CANDIDATE_BASES[0], p)

DIFFUSION_GGUF = _find("models/diffusion_models/minimax_h3_ref2va_pruned-Q4_K.gguf")
DIFFUSION_GGUF_ALT = _find("models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf")
LLM_GGUF_Q2 = _find("models/text_encoders/qwen3vl_32b_minimax_h3-Q2_K_M.gguf")
LLM_GGUF_Q4 = _find("models/text_encoders/qwen3vl_32b_minimax_h3-Q4_K_M.gguf")
VAE_VIDEO = _find("models/vae/minimax_h3_video_vae_fp16.safetensors")
VAE_VIDEO_INT8 = _find("models/vae/minimax_h3_video_vae_int8_convrot.safetensors")
VAE_AUDIO = _find("models/vae/minimax_h3_audio_vae_fp32.safetensors")

def _pick_diffusion():
    for p in [DIFFUSION_GGUF, DIFFUSION_GGUF_ALT, "/workspace/models/diffusion_models/minimax_h3_ref2va_pruned-Q4_K.gguf", "/runpod-volume/models/diffusion_models/minimax_h3_ref2va_pruned-Q4_K.gguf"]:
        if os.path.exists(p):
            return p
    return DIFFUSION_GGUF

def _pick_llm():
    for p in [LLM_GGUF_Q2, LLM_GGUF_Q4, "/workspace/models/text_encoders/qwen3vl_32b_minimax_h3-Q2_K_M.gguf", "/runpod-volume/models/text_encoders/qwen3vl_32b_minimax_h3-Q2_K_M.gguf"]:
        if os.path.exists(p):
            return p
    return LLM_GGUF_Q2

def _pick_vae():
    for p in [VAE_VIDEO, VAE_VIDEO_INT8, "/workspace/models/vae/minimax_h3_video_vae_fp16.safetensors", "/runpod-volume/models/vae/minimax_h3_video_vae_fp16.safetensors"]:
        if os.path.exists(p):
            return p
    return VAE_VIDEO

def validate_input(inp):
    if inp is None:
        return None, "Please provide input"
    if isinstance(inp, str):
        try:
            inp = json.loads(inp)
        except:
            return None, "Invalid JSON"
    if "workflow" in inp and "prompt" not in inp:
        return None, "ComfyUI workflow no longer supported — this worker is sd-cli only. Send {prompt, width, height, video_frames, steps, images}"
    if "prompt" not in inp:
        return None, "Missing 'prompt' parameter"
    _len = inp.get("length", inp.get("video_frames", 81))
    return {"prompt": inp.get("prompt",""), "width": int(inp.get("width",768)), "height": int(inp.get("height",432)), "length": int(_len), "steps": int(inp.get("steps",20)), "seed": int(inp.get("seed",-1)), "images": inp.get("images"), "negative_prompt": inp.get("negative_prompt","")}, None

def run_sd_cli(job_id, prompt, width, height, length, steps, seed, images, negative_prompt=""):
    diff = _pick_diffusion()
    llm = _pick_llm()
    vae = _pick_vae()
    vae_audio = VAE_AUDIO if os.path.exists(VAE_AUDIO) else _find("models/vae/minimax_h3_audio_vae_fp32.safetensors")
    missing = []
    for p, name in [(diff, "diffusion"), (llm, "llm Qwen"), (vae, "vae video"), (vae_audio, "vae audio")]:
        if not os.path.exists(p):
            missing.append(f"{name} missing: {p}")
    if missing:
        return {"error": "Missing models for sd-cli: " + "; ".join(missing) + ". Run POD_BAKE_COMMAND.sh"}

    tmpdir = tempfile.mkdtemp(prefix="h3_")
    ref_args = []
    if images:
        for i, im in enumerate(images[:9]):
            try:
                name = im.get("name", f"ref_{i}.png")
                uri = im.get("image", "")
                b64 = uri.split(",",1)[1] if "," in uri else uri
                blob = base64.b64decode(b64)
                ext = os.path.splitext(name)[1] or ".png"
                fp = os.path.join(tmpdir, f"ref_{i}{ext}")
                with open(fp, "wb") as f:
                    f.write(blob)
                ref_args.extend(["--image", fp])
            except Exception as e:
                print(f"[h3 sd-cli] ref {i} write err {e}")

    out_path = os.path.join(tmpdir, "out.mp4")
    if seed == -1:
        seed = int.from_bytes(os.urandom(4), "little") % 2147483647

    use_fa = os.environ.get("H3_FA", "0") == "1"
    cmd = [
        "sd-cli", "--mode", "vid_gen",
        "--diffusion-model", diff,
        "--llm", llm,
        "--vae", vae,
        "--audio-vae", vae_audio,
        "--prompt", prompt,
        "--width", str(width),
        "--height", str(height),
        "--video-frames", str(length),
        "--steps", str(steps),
        "--cfg-scale", "1.0",
        "--seed", str(seed),
        "--output", out_path,
        "--backend", "te=cpu",
        "--offload-to-cpu",
    ]
    if use_fa:
        cmd.append("--diffusion-fa")
    if negative_prompt:
        cmd.extend(["--negative-prompt", negative_prompt])
    cmd.extend(ref_args)

    print(f"[h3 sd-cli] cmd: {' '.join(shlex.quote(c) for c in cmd)}", flush=True)
    start = time.time()
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        out_buf = []
        try:
            for line in proc.stdout:
                line = line.rstrip()
                out_buf.append(line)
                print(f"[sd-cli] {line}", flush=True)
                if len(out_buf) > 500:
                    out_buf = out_buf[-400:]
        except Exception as e:
            print(f"[h3 sd-cli] stream read err {e}", flush=True)
        try:
            ret = proc.wait(timeout=900)
        except subprocess.TimeoutExpired:
            proc.kill()
            return {"error": "sd-cli timeout 900s"}
        print(f"[h3 sd-cli] exit {ret} in {time.time()-start:.1f}s", flush=True)
        tail = "\n".join(out_buf[-80:])
        if ret != 0:
            return {"error": f"sd-cli failed exit {ret}", "details": [tail]}
        if not os.path.exists(out_path):
            cands = [p for p in os.listdir(tmpdir) if p.endswith((".mp4",".webm",".mkv"))]
            if cands:
                out_path = os.path.join(tmpdir, cands[0])
            else:
                return {"error": "sd-cli produced no output", "details": [tail]}
        with open(out_path, "rb") as f:
            data = f.read()
        if os.environ.get("BUCKET_ENDPOINT_URL"):
            try:
                with tempfile.NamedTemporaryFile(suffix=".mp4", delete=False) as tf:
                    tf.write(data)
                    tfp = tf.name
                url = rp_upload.upload_image(job_id, tfp)
                os.remove(tfp)
                return {"images": [{"filename": os.path.basename(out_path), "type": "s3_url", "data": url}]}
            except Exception as e:
                print(f"[h3 sd-cli] S3 err {e}")
        b64 = base64.b64encode(data).decode()
        return {"images": [{"filename": os.path.basename(out_path), "type": "base64", "data": b64}]}
    except FileNotFoundError:
        return {"error": "sd-cli binary not found — image needs rebuild with -DSD_CUDA=ON"}

def handler(job):
    if is_network_volume_debug_enabled():
        try: run_network_volume_diagnostics()
        except: pass
    inp = job["input"]
    validated, err = validate_input(inp)
    if err:
        return {"error": err}
    print(f"[h3] sd-cli mode prompt={validated['prompt'][:80]} {validated['width']}x{validated['height']} len={validated['length']}")
    return run_sd_cli(job["id"], validated["prompt"], validated["width"], validated["height"], validated["length"], validated["steps"], validated["seed"], validated["images"], validated.get("negative_prompt",""))

if __name__ == "__main__":
    print("[h3] starting handler (sd-cli ONLY, no ComfyUI)...")
    runpod.serverless.start({"handler": handler})
