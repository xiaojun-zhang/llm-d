#!/usr/bin/env bash
# Generate a video from the running vLLM-Omni Wan2.2 server (see build-and-serve.sh).
# Uses the synchronous endpoint, which returns the mp4 bytes directly and reports
# server-side inference time via the X-Inference-Time-S response header.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8091}"
PROMPT="${PROMPT:-A cinematic shot of a red fox walking through a snowy forest at sunrise, soft golden light}"
WIDTH="${WIDTH:-480}"; HEIGHT="${HEIGHT:-480}"
FRAMES="${FRAMES:-17}"; FPS="${FPS:-16}"; STEPS="${STEPS:-20}"
OUT="${OUT:-wan_out.mp4}"

echo "Generating ${WIDTH}x${HEIGHT}, ${FRAMES} frames, ${STEPS} steps ..."
curl -sS -D /tmp/wan_hdr -o "$OUT" -X POST "$BASE_URL/v1/videos/sync" \
  -F "prompt=$PROMPT" \
  -F "width=$WIDTH" -F "height=$HEIGHT" \
  -F "num_frames=$FRAMES" -F "fps=$FPS" \
  -F "num_inference_steps=$STEPS" \
  -F "guidance_scale=5.0" -F "seed=42"

echo "Saved $OUT  (inference time: $(grep -i x-inference-time /tmp/wan_hdr | tr -d '\r' | awk '{print $2}')s)"
file "$OUT"
