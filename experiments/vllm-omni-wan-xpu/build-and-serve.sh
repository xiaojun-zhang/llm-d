#!/usr/bin/env bash
# Build the vLLM-Omni XPU image and serve Wan2.2 text-to-video on Intel Arc (B60).
# Standalone (no Kubernetes) path. See ANALYSIS-llm-d-benefit.md for the llm-d path.
#
# Validated 2026-06-01 on 8× Intel Arc Pro B60 (Battlemage), Ubuntu 24.04, kernel 6.17.
set -euo pipefail

VLLM_OMNI_SRC="${VLLM_OMNI_SRC:-$HOME/source_code/llm-d/.cache/vllm-omni}"
IMAGE="${IMAGE:-vllm-omni-xpu:local}"
MODEL="${MODEL:-Wan-AI/Wan2.2-TI2V-5B-Diffusers}"   # or Wan-AI/Wan2.2-T2V-A14B-Diffusers (needs multi-GPU)
PORT="${PORT:-8091}"
GPU="${GPU:-0}"

# 1. Clone vLLM-Omni (full clone — setuptools_scm needs git tags to derive the version).
if [ ! -d "$VLLM_OMNI_SRC/.git" ]; then
  git clone https://github.com/vllm-project/vllm-omni.git "$VLLM_OMNI_SRC"
fi

# 2. Build the XPU image (Intel oneAPI 2025.3 + vLLM 0.22.0 source + vllm-omni, triton-xpu 3.7.0).
DOCKER_BUILDKIT=1 docker build -f "$VLLM_OMNI_SRC/docker/Dockerfile.xpu" \
  -t "$IMAGE" --shm-size=4g "$VLLM_OMNI_SRC"

# 3. Serve. --vae-use-slicing/--vae-use-tiling are REQUIRED on 24 GB cards
#    (without them, 704x704/25-frame OOMs: "xe [drm] VM worker error: -12").
#    --enforce-eager avoids torch.compile warmup on the first request.
docker rm -f wan-omni >/dev/null 2>&1 || true
docker run -d --name wan-omni \
  --net=host --ipc=host --privileged \
  -v /dev/dri/by-path:/dev/dri/by-path --device /dev/dri:/dev/dri \
  -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
  --env "HF_TOKEN=${HF_TOKEN:-}" \
  --env "ZE_AFFINITY_MASK=$GPU" \
  "$IMAGE" \
  "$MODEL" --port "$PORT" --enforce-eager --vae-use-slicing --vae-use-tiling

echo "Serving $MODEL on port $PORT (GPU $GPU). Waiting for /health ..."
for _ in $(seq 1 30); do
  sleep 10
  if curl -sf --max-time 3 "http://localhost:$PORT/health" >/dev/null 2>&1; then
    echo "READY. Try: ./generate.sh"
    exit 0
  fi
done
echo "Server did not become ready; check: docker logs wan-omni"
exit 1
