#!/usr/bin/env bash
set -euo pipefail

host="${HOST:-127.0.0.1}"
port="${PORT:-8000}"

curl -sS "http://${host}:${port}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "moonshotai/Kimi-VL-A3B-Instruct",
    "messages": [
      {
        "role": "user",
        "content": [
          {
            "type": "image_url",
            "image_url": {
              "url": "https://images.dog.ceo/breeds/retriever-golden/n02099601_3004.jpg"
            }
          },
          {
            "type": "text",
            "text": "What is in this image?"
          }
        ]
      }
    ],
    "max_tokens": 32
  }' | jq .
