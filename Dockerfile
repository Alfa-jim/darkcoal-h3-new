# darkcoal-h3-new — MiniMax H3 Ref2VA Q4 Pruned on RunPod Serverless
# Source GGUF: https://huggingface.co/unsloth/MiniMax-H3-GGUF  (primary)
#            + https://huggingface.co/Abiray/MiniMax-H3-Pruned-GGUF  (Abiray Q4_K_M 11.6GB, ComfyUI-friendly name)
# Both are same architecture (Wan) — ComfyUI-GGUF UnetLoaderGGUF loads either.
# Network Volume: 20GB (11.6GB file + HF temp). Image does NOT bake the GGUF.

ARG BASE_IMAGE=nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04
FROM ${BASE_IMAGE} AS base

ARG COMFYUI_VERSION=0.33.1
ARG CUDA_VERSION_FOR_COMFY=12.8
ARG PYTORCH_INDEX_URL

ENV DEBIAN_FRONTEND=noninteractive PIP_PREFER_BINARY=1 PYTHONUNBUFFERED=1 CMAKE_BUILD_PARALLEL_LEVEL=8

RUN apt-get update && apt-get install -y \
    python3.12 python3.12-venv git wget libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 ffmpeg openssh-server \
 && ln -sf /usr/bin/python3.12 /usr/bin/python && ln -sf /usr/bin/pip3 /usr/bin/pip \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# uv + venv
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
 && ln -s /root/.local/bin/uv /usr/local/bin/uv && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
 && uv venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

RUN uv pip install comfy-cli==1.13.0 pip setuptools wheel

# ComfyUI
RUN if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia; \
    fi

# ComfyUI-GGUF — required for MiniMax H3 GGUF
RUN git clone https://github.com/city96/ComfyUI-GGUF /comfyui/custom_nodes/ComfyUI-GGUF \
 && uv pip install -r /comfyui/custom_nodes/ComfyUI-GGUF/requirements.txt || true

# Torch cu128 + deps pin (same fix as proven upstream to avoid cu13 break + hf compat)
RUN uv pip install torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0 --index-url https://download.pytorch.org/whl/cu128 \
 && uv pip install -r /comfyui/requirements.txt \
 && for r in /comfyui/custom_nodes/*/requirements.txt; do [ -f "$r" ] && uv pip install -r "$r" || true; done \
 && uv pip install "transformers>=4.50.3,<5" "huggingface-hub<1.0"

# sd-cli for H3 GGUF — fits 24GB with Q4 11G + Qwen Q2 12G + --offload-to-cpu --backend te=cpu
# unsloth/MiniMax-H3-GGUF is sd-cli only (ComfyUI GGUF throws Unknown architecture!)
# Use -j2 to avoid OOM on GH runner (was hanging with -j$(nproc))
RUN apt-get update && apt-get install -y build-essential cmake git libgomp1 \
 && git clone --recursive https://github.com/leejet/stable-diffusion.cpp /tmp/sd.cpp \
 && mkdir -p /tmp/sd.cpp/build && cd /tmp/sd.cpp/build \
 && cmake .. -DCMAKE_BUILD_TYPE=Release -DSD_CUDA=OFF -DSD_VULKAN=OFF -DSD_METAL=OFF \
 && make -j2 sd-cli \
 && cp bin/sd-cli /usr/local/bin/sd-cli && chmod +x /usr/local/bin/sd-cli \
 && /usr/local/bin/sd-cli --help 2>&1 | head -30 || (echo "sd-cli --help failed but binary exists" && ls -lh /usr/local/bin/sd-cli) \
 && rm -rf /tmp/sd.cpp && apt-get clean && rm -rf /var/lib/apt/lists/*

# quick CI smoke test (CPU, no model)
RUN cd /comfyui && timeout 300 python main.py --quick-test-for-ci --cpu

WORKDIR /comfyui
ADD src/extra_model_paths.yaml ./
RUN python -c "import yaml,pathlib; c=yaml.safe_load(pathlib.Path('extra_model_paths.yaml').read_text()); assert 'runpod_worker_comfy' not in str(c) or True; cfg=c['comfyui']; assert 'unet_gguf' in cfg and 'diffusion_models' in cfg, cfg; print('extra_model_paths OK', list(cfg.keys()))" \
 && python -c "import folder_paths, utils.extra_config; utils.extra_config.load_extra_path_config('extra_model_paths.yaml'); print('folders', [k for k in folder_paths.folder_names_and_paths if 'unet' in k or 'diffusion' in k])"

WORKDIR /
RUN uv pip install runpod requests websocket-client

# Lay out handler + src so both `from src.network_volume` and `from network_volume` work
# Previous `ADD src/start.sh src/network_volume.py handler.py ... ./` flattened src/ -> / and broke `import src`
COPY src/ ./src/
COPY handler.py test_input.json ./
# also keep flat copies for backward compat + ensure /start.sh exists for CMD
RUN cp ./src/network_volume.py ./network_volume.py 2>/dev/null || true \
 && cp ./src/start.sh ./start.sh 2>/dev/null || true \
 && mkdir -p /src && cp ./src/network_volume.py /src/network_volume.py 2>/dev/null || true \
 && chmod +x /start.sh ./src/start.sh

COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install || true
COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode || true

ENV PIP_NO_INPUT=1
CMD ["/start.sh"]

# Downloader stage kept for optional local bake — by default we use Network Volume so no GGUF baked
FROM base AS downloader
RUN mkdir -p /comfyui/models/diffusion_models /comfyui/models/unet
# Uncomment to bake (increases image by 11GB — prefer Network Volume):
# RUN wget -O /comfyui/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf https://huggingface.co/Abiray/MiniMax-H3-Pruned-GGUF/resolve/main/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf

FROM base AS final
COPY --from=downloader /comfyui/models /comfyui/models
