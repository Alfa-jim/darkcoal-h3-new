# darkcoal-h3-new — MiniMax H3 Ref2VA Q4 Pruned on RunPod Serverless (sd-cli ONLY, no ComfyUI)
# Source GGUF: https://huggingface.co/unsloth/MiniMax-H3-GGUF
# Network Volume: 20GB (11GB diffusion + 13GB Q2 + VAEs). Image does NOT bake GGUF.

ARG BASE_IMAGE=nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04
FROM ${BASE_IMAGE} AS base

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

# Torch for GPU check only (not Comfy) + handler deps
RUN uv pip install torch==2.11.0 --index-url https://download.pytorch.org/whl/cu128 \
 && uv pip install "huggingface-hub<1.0" runpod requests

# sd-cli for H3 GGUF — GPU build fits 24GB with Q4 11G + Qwen Q2 12G + --offload-to-cpu --backend te=cpu
# unsloth/MiniMax-H3-GGUF is sd-cli ONLY (ComfyUI throws Unknown architecture)
# Fix SIGILL exit -4 on RTX A5000 cc 8.6: GGML_NATIVE=OFF + CUDA arch 86 + FA OFF, -j2 for GH runner
RUN apt-get update && apt-get install -y build-essential cmake git libgomp1 \
 && git clone --recursive https://github.com/leejet/stable-diffusion.cpp /tmp/sd.cpp \
 && mkdir -p /tmp/sd.cpp/build && cd /tmp/sd.cpp/build \
 && cmake .. -DCMAKE_BUILD_TYPE=Release -DSD_CUDA=ON -DSD_VULKAN=OFF -DSD_METAL=OFF -DGGML_NATIVE=OFF -DCMAKE_CUDA_ARCHITECTURES=86 -DGGML_CUDA_FA_ALL_QUANTS=OFF \
 && make -j2 sd-cli \
 && cp bin/sd-cli /usr/local/bin/sd-cli && chmod +x /usr/local/bin/sd-cli \
 && /usr/local/bin/sd-cli --help 2>&1 | head -30 || (echo "sd-cli --help failed but binary exists" && ls -lh /usr/local/bin/sd-cli) \
 && rm -rf /tmp/sd.cpp && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /
COPY src/ ./src/
COPY handler.py test_input.json ./
RUN cp ./src/network_volume.py ./network_volume.py 2>/dev/null || true \
 && cp ./src/start.sh ./start.sh 2>/dev/null || true \
 && mkdir -p /src && cp ./src/network_volume.py /src/network_volume.py 2>/dev/null || true \
 && chmod +x /start.sh ./src/start.sh

ENV PIP_NO_INPUT=1
CMD ["/start.sh"]

# Downloader stage (unused — Network Volume)
FROM base AS downloader
RUN mkdir -p /workspace/models
FROM base AS final
COPY --from=downloader /workspace/models /workspace/models
