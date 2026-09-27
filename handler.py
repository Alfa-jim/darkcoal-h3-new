"""
darkcoal-h3-new — RunPod Serverless handler for MiniMax H3
Supports BOTH:
- sd-cli --mode vid_gen (GGUF Q4 11G + Qwen Q2 12G, fits 24GB, --offload-to-cpu --backend te=cpu)  [PRIMARY for H3]
- ComfyUI fallback (UNETLoader FP8 19.5G) if workflow supplied
"""
import base64, json, os, subprocess, tempfile, time, traceback, uuid, logging, shlex
import requests, websocket, runpod
from runpod.serverless.utils import rp_upload
from io import BytesIO
try:
    from src.network_volume import is_network_volume_debug_enabled, run_network_volume_diagnostics
except ImportError:
    try:
        from network_volume import is_network_volume_debug_enabled, run_network_volume_diagnostics
    except ImportError:
        def is_network_volume_debug_enabled(): return False
        def run_network_volume_diagnostics(): return None

logging.basicConfig(level=logging.INFO)
COMFY_HOST = "127.0.0.1:8188"
COMFY_PID_FILE = "/tmp/comfyui.pid"

# sd-cli paths — Pod /workspace == Serverless /runpod-volume (same volume)
CANDIDATE_BASES = ["/runpod-volume", "/workspace", "/comfyui"]
def _find(p):
    for b in CANDIDATE_BASES:
        fp = os.path.join(b, p)
        if os.path.exists(fp):
            return fp
    # fallback to first
    return os.path.join(CANDIDATE_BASES[0], p)

DIFFUSION_GGUF = _find("models/diffusion_models/minimax_h3_ref2va_pruned-Q4_K.gguf")
DIFFUSION_GGUF_ALT = _find("models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf")
LLM_GGUF_Q2 = _find("models/text_encoders/qwen3vl_32b_minimax_h3-Q2_K_M.gguf")
LLM_GGUF_Q4 = _find("models/text_encoders/qwen3vl_32b_minimax_h3-Q4_K_M.gguf")
LLM_SAFETENSORS = _find("models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors")
VAE_VIDEO = _find("models/vae/minimax_h3_video_vae_fp16.safetensors")
VAE_VIDEO_INT8 = _find("models/vae/minimax_h3_video_vae_int8_convrot.safetensors")
VAE_AUDIO = _find("models/vae/minimax_h3_audio_vae_fp32.safetensors")

def _pick_diffusion():
    for p in [DIFFUSION_GGUF, DIFFUSION_GGUF_ALT, "/workspace/models/diffusion_models/minimax_h3_ref2va_pruned-Q4_K.gguf", "/runpod-volume/models/diffusion_models/minimax_h3_ref2va_pruned-Q4_K.gguf"]:
        if os.path.exists(p):
            return p
    return DIFFUSION_GGUF

def _pick_llm():
    # sd-cli needs GGUF Qwen — prefer Q2 (fits 24GB), fallback Q4, fallback safetensors (won't work with sd-cli but for ComfyUI)
    for p in [LLM_GGUF_Q2, LLM_GGUF_Q4, "/workspace/models/text_encoders/qwen3vl_32b_minimax_h3-Q2_K_M.gguf", "/runpod-volume/models/text_encoders/qwen3vl_32b_minimax_h3-Q2_K_M.gguf"]:
        if os.path.exists(p):
            return p
    # if no GGUF, return Q2 path anyway (will error clearly)
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
    # sd-cli path: prompt-based (playground sends video_frames, accept both)
    if "prompt" in inp:
        _len = inp.get("length", inp.get("video_frames", 81))
        return {"mode": "sd-cli", "prompt": inp.get("prompt",""), "width": int(inp.get("width",768)), "height": int(inp.get("height",432)), "length": int(_len), "steps": int(inp.get("steps",20)), "seed": int(inp.get("seed",-1)), "images": inp.get("images"), "negative_prompt": inp.get("negative_prompt","")}, None
    # ComfyUI fallback
    wf = inp.get("workflow")
    if wf is None:
        return None, "Missing 'workflow' or 'prompt' parameter"
    images = inp.get("images")
    if images is not None and not isinstance(images, list):
        return None, "'images' must be list"
    return {"mode": "comfyui", "workflow": wf, "images": images, "comfy_org_api_key": inp.get("comfy_org_api_key")}, None

def run_sd_cli(job_id, prompt, width, height, length, steps, seed, images, negative_prompt=""):
    # check models
    diff = _pick_diffusion()
    llm = _pick_llm()
    vae = _pick_vae()
    vae_audio = VAE_AUDIO if os.path.exists(VAE_AUDIO) else _find("models/vae/minimax_h3_audio_vae_fp32.safetensors")
    missing = []
    for p, name in [(diff, "diffusion"), (llm, "llm Qwen"), (vae, "vae video"), (vae_audio, "vae audio")]:
        if not os.path.exists(p):
            missing.append(f"{name} missing: {p}")
    if missing:
        return {"error": "Missing models for sd-cli: " + "; ".join(missing) + ". Run POD_BAKE_COMMAND.sh or wget the GGUFs."}

    # prepare refs — sd-cli expects image paths via --image or --ref? For H3 ref2va, sd-cli takes --image for reference
    # We write images to temp dir and pass as --image /tmp/ref0.png --image /tmp/ref1.png
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

    # sd-cli output
    out_path = os.path.join(tmpdir, "out.mp4")
    # seed handling: sd-cli --seed -1 random
    if seed == -1:
        seed = int.from_bytes(os.urandom(4), "little") % 2147483647

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
        "--diffusion-fa",
        "--offload-to-cpu",
    ]
    # add negative prompt if any (sd-cli may not support, but try)
    if negative_prompt:
        cmd.extend(["--negative-prompt", negative_prompt])
    cmd.extend(ref_args)

    print(f"[h3 sd-cli] cmd: {' '.join(shlex.quote(c) for c in cmd)}", flush=True)
    start = time.time()
    try:
        # Stream so RunPod logs don't appear frozen (CPU 100% with buffered capture_output shows nothing until exit/OOM)
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        out_buf = []
        try:
            for line in proc.stdout:
                line = line.rstrip()
                out_buf.append(line)
                print(f"[sd-cli] {line}", flush=True)
                # keep last ~4000 chars for error reporting
                if len(out_buf) > 500:
                    out_buf = out_buf[-400:]
        except Exception as e:
            print(f"[h3 sd-cli] stream read err {e}", flush=True)
        try:
            ret = proc.wait(timeout=900)
        except subprocess.TimeoutExpired:
            proc.kill()
            return {"error": "sd-cli timeout 900s (GPU build should finish 768p/5s in ~120-180s; CPU-only hangs)"}
        print(f"[h3 sd-cli] exit {ret} in {time.time()-start:.1f}s", flush=True)
        tail = "\n".join(out_buf[-80:])
        if ret != 0:
            return {"error": f"sd-cli failed exit {ret}", "details": [tail]}
        if not os.path.exists(out_path):
            # sd-cli may output .webm or with suffix
            cands = [p for p in os.listdir(tmpdir) if p.endswith((".mp4",".webm",".mkv"))]
            if cands:
                out_path = os.path.join(tmpdir, cands[0])
            else:
                return {"error": "sd-cli produced no output", "details": [tail]}
        # read output
        with open(out_path, "rb") as f:
            data = f.read()
        # S3 vs base64
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
        return {"error": "sd-cli binary not found — image needs rebuild with stable-diffusion.cpp (needs -DSD_CUDA=ON devel image)"}
    finally:
        # cleanup refs but keep output for debugging if needed
        pass

# --- ComfyUI fallback (kept for compatibility) ---
COMFY_HOST = "127.0.0.1:8188"
COMFY_PID_FILE = "/tmp/comfyui.pid"
def _comfy_alive():
    try:
        pid = int(open(COMFY_PID_FILE).read().strip())
        os.kill(pid, 0)
        return True
    except:
        return False

def check_server(url, retries=0, delay=50):
    import requests as req
    print(f"[h3] Checking ComfyUI at {url}...")
    attempt = 0
    while True:
        try:
            r = req.get(url, timeout=5)
            if r.status_code == 200:
                print("[h3] ComfyUI reachable")
                return True
        except:
            pass
        attempt += 1
        fallback = retries if retries > 0 else 500
        if _comfy_alive() is False:
            print("[h3] ComfyUI exited")
            return False
        if attempt >= fallback:
            return False
        time.sleep(delay/1000)

def handler(job):
    if is_network_volume_debug_enabled():
        try:
            run_network_volume_diagnostics()
        except:
            pass
    inp = job["input"]
    validated, err = validate_input(inp)
    if err:
        return {"error": err}
    if validated["mode"] == "sd-cli":
        print(f"[h3] sd-cli mode prompt={validated['prompt'][:80]} {validated['width']}x{validated['height']} len={validated['length']}")
        return run_sd_cli(job["id"], validated["prompt"], validated["width"], validated["height"], validated["length"], validated["steps"], validated["seed"], validated["images"], validated.get("negative_prompt",""))
    # ComfyUI path
    import requests, websocket, uuid, urllib.parse
    workflow = validated["workflow"]
    input_images = validated.get("images")
    if not check_server(f"http://{COMFY_HOST}/", 0, 50):
        return {"error": f"ComfyUI server ({COMFY_HOST}) not reachable"}
    # upload images
    if input_images:
        for im in input_images:
            try:
                name = im["name"]
                uri = im["image"]
                b64 = uri.split(",",1)[1] if "," in uri else uri
                blob = base64.b64decode(b64)
                files = {"image": (name, BytesIO(blob), "image/png"), "overwrite": (None, "true")}
                r = requests.post(f"http://{COMFY_HOST}/upload/image", files=files, timeout=30)
                r.raise_for_status()
            except Exception as e:
                return {"error": f"Failed to upload {im.get('name')}: {e}"}
    # queue via ComfyUI (simplified)
    try:
        client_id = str(uuid.uuid4())
        payload = {"prompt": workflow, "client_id": client_id}
        if validated.get("comfy_org_api_key"):
            payload["extra_data"] = {"api_key_comfy_org": validated["comfy_org_api_key"]}
        r = requests.post(f"http://{COMFY_HOST}/prompt", data=json.dumps(payload).encode(), headers={"Content-Type":"application/json"}, timeout=30)
        if r.status_code == 400:
            try:
                err = r.json()
                return {"error": f"Workflow validation failed: {err}"}
            except:
                return {"error": f"Validation failed: {r.text[:1500]}"}
        r.raise_for_status()
        qd = r.json()
        prompt_id = qd.get("prompt_id")
        if not prompt_id:
            return {"error": f"Missing prompt_id in {qd}"}
        # wait via websocket (simplified polling)
        ws = websocket.WebSocket()
        ws.connect(f"ws://{COMFY_HOST}/ws?clientId={client_id}", timeout=10)
        done = False
        while True:
            out = ws.recv()
            if isinstance(out, str):
                m = json.loads(out)
                if m.get("type") == "executing" and m.get("data",{}).get("node") is None and m.get("data",{}).get("prompt_id") == prompt_id:
                    done = True
                    break
                if m.get("type") == "execution_error" and m.get("data",{}).get("prompt_id") == prompt_id:
                    return {"error": f"Workflow execution error: {m.get('data')}"}
        ws.close()
        # fetch history
        r = requests.get(f"http://{COMFY_HOST}/history/{prompt_id}", timeout=30)
        r.raise_for_status()
        hist = r.json()
        if prompt_id not in hist:
            return {"error": f"prompt {prompt_id} not in history"}
        outputs = hist[prompt_id].get("outputs",{})
        from runpod.serverless.utils import rp_upload as _rp
        out_list = []
        for nid, nout in outputs.items():
            for mk in ("images","gifs","videos","audio","audios"):
                for info in nout.get(mk,[]):
                    fn = info.get("filename")
                    sub = info.get("subfolder","")
                    ftype = info.get("type")
                    if not fn or ftype == "temp":
                        continue
                    qs = urllib.parse.urlencode({"filename": fn, "subfolder": sub, "type": ftype})
                    rb = requests.get(f"http://{COMFY_HOST}/view?{qs}", timeout=60).content
                    if os.environ.get("BUCKET_ENDPOINT_URL"):
                        with tempfile.NamedTemporaryFile(suffix=os.path.splitext(fn)[1] or ".mp4", delete=False) as tf:
                            tf.write(rb)
                            tfp = tf.name
                        url = _rp.upload_image(job["id"], tfp)
                        os.remove(tfp)
                        out_list.append({"filename": fn, "type": "s3_url", "data": url})
                    else:
                        out_list.append({"filename": fn, "type": "base64", "data": base64.b64encode(rb).decode()})
        if not out_list:
            return {"error": "No outputs"}
        return {"images": out_list}
    except Exception as e:
        print(f"[h3] ComfyUI err {e}\n{traceback.format_exc()}")
        return {"error": str(e)}

if __name__ == "__main__":
    print("[h3] starting handler (sd-cli + ComfyUI fallback)...")
    runpod.serverless.start({"handler": handler})
