# darkcoal-h3-new — MiniMax H3 Ref2VA Q4 Pruned · RunPod Serverless Worker

> **For darkcoal.online AI ads:** `Ref2VA` = character-consistent video **+ synchronized audio** (24 FPS + 32kHz stereo). Up to **9 reference images** / 3 videos / 3 audios — max **12 assets** in one call. Single GPU.

Fork-free, brand-new repo for **video generation worker** on RunPod with a **20GB Network Volume**. Based solely on **https://huggingface.co/unsloth/MiniMax-H3-GGUF** — Q4 Pruned Ref2VA variant.

|  |  |
|---|---|
| **Model file** | `MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf` — **11.6 GB** `Q4_K_M` (Abiray pruned). Alt upstream: `minimax_h3_ref2va_pruned-Q4_K.gguf` from `unsloth/MiniMax-H3-GGUF`. Both are Wan-arch GGUF, loaded by `UnetLoaderGGUF`. |
| **Output** | 4-15s, any aspect (16:9 / 9:16 / 1:1), 768p native, 24 FPS, stereo 32kHz. Longer via prompt duration. |
| **VRAM** | ~13-15GB peak → **A6000 48GB / RTX 4090 24GB / L4 24GB** recommended. Q3 works on 16GB but slower. |
| **License** | `minimax-h3-community-license-agreement` (https://huggingface.co/MiniMaxAI/MiniMax-H3/blob/main/LICENSE) |
| **Image** | `ghcr.io/alfa-jim/darkcoal-h3-new:latest` (auto-built by GitHub Actions — just hit **Run workflow**) |

### Why 20 GB Network Volume?

11.6 GB file + HuggingFace 2× temp during download + ComfyUI output cache → **20 GB is minimum sweet spot ($1.40/mo at $0.07/GB)**. Not 30 GB. Must be a **Network Volume** (Serverless), not Global Volume (Pods-only Beta).

---

## Deploy — 10 minutes

### 0) Prereqs

- GitHub repo `Alfa-jim/darkcoal-h3-new` (this folder) — push once, GHCR builds automatically.
- RunPod account + $10.
- Create **Network Volume 20 GB**: RunPod Console → Storage → `+ New` → **Network Volume** → name `darkcoal-h3` 20 GB → pick **one datacenter** (e.g. `EU-RO-1`). You must reuse the **same region** for Serverless workers.

### 1) Bake model into the Network Volume (one-time, ~3 min via Pod)

> ⚠️  Pod shows the volume at **`/workspace`**, Serverless shows the **same** volume at **`/runpod-volume`** (via `extra_model_paths.yaml`). The bake script deliberately writes to `/workspace` per instruction and symlinks to `/runpod-volume`.

```bash
# Console → Pods → Deploy → Community → RTX 4090 (CPU is fine, no GPU needed)
#  → Attach Network Volume: darkcoal-h3 (20 GB, same region!) → Deploy → Connect

bash POD_BAKE_COMMAND.sh
# or: chmod +x POD_BAKE_COMMAND.sh && ./POD_BAKE_COMMAND.sh

# expect:
# Downloaded 11.60 GB → /workspace/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf
# Symlink /workspace/models/unet/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf
# === SUCCESS — volume baked ===
```

If SSH drops, re-run — **resumes safely**. When done: **Stop / Terminate the Pod** — the Network Volume persists.

`POD_BAKE_COMMAND.sh` also handles:

- `huggingface-cli` with `hf_transfer` → fallback `aria2c` / `wget -c` if cli fails
- GGUF magic validation + size check
- Cross-linking `/workspace` ↔ `/runpod-volume` for both mount views
- Optional VAE helpers `vae/minimax_h3_video_vae_*` from `unsloth/MiniMax-H3-GGUF`

> To bake the **upstream unsloth** filename instead, edit the top of `POD_BAKE_COMMAND.sh`:
> ```bash
> REPO="unsloth/MiniMax-H3-GGUF"
> FILE="minimax_h3_ref2va_pruned-Q4_K.gguf"
> ```

Verify:

```bash
ls -lh /workspace/models/diffusion_models/
# must show 11.6G
ls -lh /workspace/models/unet/
ls -lh /runpod-volume/models/diffusion_models/  # same via symlink
```

### 2) Build & Push Docker (automatic via GHCR)

**No Docker Desktop needed.** Push this folder to GitHub and Actions builds `ghcr.io/alfa-jim/darkcoal-h3-new:latest`:

1. Push repo → Actions tab → **Build and Push GHCR — darkcoal-h3-new** → `Run workflow` → done in ~6 min.
2. Or local build:

```powershell
cd "C:\Users\dutap\OneDrive\Desktop\DSH workspace\darkcoal-h3-new"
docker buildx build --platform linux/amd64 -t ghcr.io/alfa-jim/darkcoal-h3-new:latest . --push
```

### 3) Create Serverless Endpoint

1. https://console.runpod.io/serverless → **New Endpoint**
2. **Container Image:** `ghcr.io/alfa-jim/darkcoal-h3-new:latest`
3. **Container Disk:** `25 GB`
4. **Volume:** Attach **Network Volume** `darkcoal-h3` (same datacenter as workers). It mounts at `/runpod-volume` inside the worker.
5. **Env:** none required (optional `HF_TOKEN`, or `NETWORK_VOLUME_DEBUG=true` for diagnostics)
6. **Workers:** `Min 0` (must for $0 idle), `Max 2`, `Idle 5s`, `Execution 300s` (video gen is long — 150-200s)
7. **GPU:** `Flex → A6000 (priority) + 4090` or just `A6000` — cheapest is A6000 Secure $0.53/hr
8. Save → copy `ENDPOINT_ID`

### 4) Test — text-to-video (no refs, T2VA)

```powershell
$ENDPOINT="YOUR_ENDPOINT_ID"
$KEY="rpa_..."

$body = Get-Content "test_input.json" -Raw
$job = Invoke-RestMethod -Uri "https://api.runpod.ai/v2/$ENDPOINT/runsync" -Method Post -Headers @{Authorization="Bearer $KEY"; "Content-Type"="application/json"} -Body $body
$job | ConvertTo-Json -Depth 5

# output.images[0].data is base64 mp4 when S3 not configured
$out = $job.output.images | Where-Object { $_.filename -like "*.mp4" } | Select-Object -First 1
if(-not $out){ $out = $job.output.images[0] }
if($out.type -eq "base64"){
  [IO.File]::WriteAllBytes(".\ad_test.mp4", [Convert]::FromBase64String($out.data))
  Invoke-Item ".\ad_test.mp4"
} else { Write-Host "S3 URL: $($out.data)" }
```

Or open **`playground.html`** locally → paste endpoint + key → Generate.

### 5) Generate Ad with Character Refs (Ref2VA)

Refs are sent as `images` array (base64 data-uri). The workflow must have matching `LoadImageSet` / `LoadImage` nodes.

```json
{
  "input": {
    "workflow": { "... exported ComfyUI API graph (Save API Format) ..." },
    "images": [
      {"name": "char_0_0.png", "image": "data:image/png;base64,..."},
      {"name": "char_0_1.png", "image": "data:image/png;base64,..."}
    ]
  }
}
```

**Ad tip (5-6s, 16:9):** `"cinematic ad for AI roleplay app, beautiful woman with [desc], luxury bedroom, soft bokeh, winks at camera, whispers 'your story awaits', 4k, 24fps"` — Ref2VA locks identity.

---

## Playground — `playground.html`

Local single-file studio (no build) for darkcoal.online ads:

- **Characters vault** — create character → upload up to 9 ref images (front / side / outfit) → **Use** → becomes active refs. Stored in `localStorage` (base64). Preserved across refresh.
- **Scenes** — prompt snippets + built-ins (luxury bedroom, neon club, beach sunset, fantasy tavern, office noir, cyber street…) → Use → appends to prompt.
- **Backgrounds** — plate images + prompt tokens.
- **Sounds** — optional audio refs (mp3/wav) + video refs (mp4) — up to 3 each, total ≤12.
- **Ad presets** — one-click 5-6s hooks that convert (Whisper Close, Bedroom Reveal, Club Tease, Fantasy Tavern, Beach Walk, Cyber Rain).
- **Active refs** — reorder (first = strongest identity), clear, shuffle. Shows `T2VA` vs `Ref2VA (n refs)`.
- **Generate** — builds workflow or uses your custom ComfyUI API JSON, POSTs to `/runsync` or `/run` (polls `/status`), previews video, gallery, download.
- **Projects** — bundle prompt + refs + settings → save → export/import `.json` for team share.
- Everything is **localStorage** — no server.

Open `playground.html` directly in a browser (double-click). Fill `endpoint` + `apikey` at top.

---

## Cost

- **Idle:** $0 (Min 0)
- **Warm gen (A6000):** `~150s × $0.53/hr / 3600 = $0.022/video` vs API $0.40-$0.65
- **Volume:** 20 GB × $0.07 = **$1.40/mo**
- **500 ads/mo:** ~$13 compute + $1.40 storage vs ~$280 via API

## Troubleshooting

- `ComfyUI server not reachable` → rebuild with `--platform linux/amd64`, check `docker logs` and `start.sh` GPU check. This image uses `torch cu128`.
- `unet_name not in list` → volume not mounted or file not at `/runpod-volume/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf` → check `extra_model_paths.yaml` has `unet_gguf: models/diffusion_models/`.
- Video not returned (`gifs`/`videos` dropped) → this handler captures `images` + `gifs` + `videos` + `audio` and returns `media_type` — mp4 under `gifs`/`videos` is not dropped.
- OOM → ensure GPU 24GB+, use `Q4_K_M` not `Q6`, set `width 768` not `1280`.
- Slow cold start → enable FlashBoot + volume **same region** as workers.
- `NETWORK_VOLUME_DEBUG=true` → prints mount/model diagnostics at job start.

## Files

```
darkcoal-h3-new/
  Dockerfile                      # CUDA 12.8 + ComfyUI 0.33.1 + ComfyUI-GGUF + torch cu128
  handler.py                      # RunPod handler (websocket, 12 assets, S3/base64)
  src/start.sh                    # GPU check + /workspace→/runpod-volume compat + ComfyUI launch
  src/extra_model_paths.yaml      # /runpod-volume base_path, unet_gguf → diffusion_models
  src/network_volume.py           # NETWORK_VOLUME_DEBUG diagnostics
  .github/workflows/build.yml     # GHCR build (linux/amd64, cache gha, one-click)
  POD_BAKE_COMMAND.sh             # Pod bake → /workspace (Serverless sees /runpod-volume)
  playground.html                 # darkcoal.online Ad Studio (characters, scenes, backgrounds, sounds, projects)
  test_input.json                 # minimal T2VA payload (no refs)
  workflows/ref2va_q4_api.json    # example Ref2VA graph
  scripts/                        # comfy helpers
```

## License

Code MIT. Model weights under `minimax-h3-community-license-agreement`.
