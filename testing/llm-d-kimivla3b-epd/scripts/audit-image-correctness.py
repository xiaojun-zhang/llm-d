#!/usr/bin/env python3
"""Send fixed visual prompts to an OpenAI-compatible chat endpoint.

The script creates simple deterministic images, sends them as data URLs, and
saves the image files, request metadata, raw responses, and a JSONL summary.
It is intended for quick 1AGG vs E/PD semantic checks, not performance testing.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import time
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path
from typing import Any

import requests
from PIL import Image, ImageDraw, ImageFont


DEFAULT_MODEL = "/mnt/weka/data/llm-d-models-pv/hub/models--moonshotai--Kimi-VL-A3B-Instruct/snapshots/main"


@dataclass
class AuditCase:
    name: str
    prompt: str
    images: list[Image.Image]
    expected_keywords: list[str | list[str]]


def _font(size: int) -> ImageFont.ImageFont:
    for path in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf",
    ):
        if Path(path).is_file():
            return ImageFont.truetype(path, size=size)
    return ImageFont.load_default()


def _centered_text(draw: ImageDraw.ImageDraw, xyxy: tuple[int, int, int, int], text: str, font: ImageFont.ImageFont) -> None:
    left, top, right, bottom = xyxy
    bbox = draw.textbbox((0, 0), text, font=font)
    width = bbox[2] - bbox[0]
    height = bbox[3] - bbox[1]
    x = left + (right - left - width) / 2
    y = top + (bottom - top - height) / 2
    draw.text((x, y), text, fill=(0, 0, 0), font=font)


def make_cases() -> list[AuditCase]:
    red = Image.new("RGB", (512, 512), (215, 24, 32))
    draw = ImageDraw.Draw(red)
    draw.rectangle((8, 8, 504, 504), outline=(0, 0, 0), width=6)

    number = Image.new("RGB", (512, 512), (255, 255, 255))
    draw = ImageDraw.Draw(number)
    draw.rectangle((8, 8, 504, 504), outline=(0, 0, 0), width=6)
    _centered_text(draw, (0, 0, 512, 512), "42", _font(220))

    shapes = Image.new("RGB", (512, 512), (255, 255, 255))
    draw = ImageDraw.Draw(shapes)
    draw.rectangle((8, 8, 504, 504), outline=(0, 0, 0), width=6)
    draw.ellipse((58, 156, 258, 356), fill=(40, 90, 220), outline=(0, 0, 0), width=4)
    draw.rectangle((314, 156, 454, 356), fill=(36, 170, 76), outline=(0, 0, 0), width=4)

    return [
        AuditCase(
            name="dominant_red",
            prompt="What is the dominant color of this image? Answer with one lowercase word.",
            images=[red],
            expected_keywords=["red"],
        ),
        AuditCase(
            name="ocr_42",
            prompt="What number is shown in the image? Answer with digits only.",
            images=[number],
            expected_keywords=["42"],
        ),
        AuditCase(
            name="two_shapes",
            prompt="Name the two colored shapes in the image. Answer as '<color> <shape>, <color> <shape>'.",
            images=[shapes],
            expected_keywords=["blue", "circle", "green", ["square", "rectangle"]],
        ),
        AuditCase(
            name="multi_image_order",
            prompt="The first image is a solid color and the second image contains a number. What color is first, and what number is second?",
            images=[red, number],
            expected_keywords=["red", "42"],
        ),
    ]


def image_to_data_url(image: Image.Image) -> tuple[str, bytes]:
    buf = BytesIO()
    image.save(buf, format="PNG")
    data = buf.getvalue()
    encoded = base64.b64encode(data).decode("ascii")
    return f"data:image/png;base64,{encoded}", data


def get_default_model(base_url: str, timeout: float) -> str:
    response = requests.get(f"{base_url}/v1/models", timeout=timeout)
    response.raise_for_status()
    payload = response.json()
    data = payload.get("data") or []
    if not data:
        raise RuntimeError(f"No models returned from {base_url}/v1/models: {payload}")
    return data[0]["id"]


def response_text(response_json: dict[str, Any]) -> str:
    choices = response_json.get("choices") or []
    if not choices:
        return ""
    message = choices[0].get("message") or {}
    return (message.get("reasoning_content") or "") + (message.get("content") or "")


def score_text(text: str, keywords: list[str | list[str]]) -> dict[str, Any]:
    lower = text.lower()
    matched = []
    missing = []
    for keyword in keywords:
        aliases = keyword if isinstance(keyword, list) else [keyword]
        match = next((alias for alias in aliases if alias.lower() in lower), None)
        if match is None:
            missing.append(keyword)
        else:
            matched.append(match)
    unable = any(marker in lower for marker in ("unable", "cannot", "can't", "can not"))
    return {
        "matched_keywords": matched,
        "missing_keywords": missing,
        "expected_keywords": keywords,
        "passed": not missing and not unable,
        "looks_unable": unable,
    }


def write_json(path: Path, payload: Any) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run_case(case: AuditCase, base_url: str, model: str, out_dir: Path, timeout: float, max_tokens: int) -> dict[str, Any]:
    case_dir = out_dir / case.name
    case_dir.mkdir(parents=True, exist_ok=True)

    content: list[dict[str, Any]] = []
    saved_images = []
    for idx, image in enumerate(case.images):
        data_url, image_bytes = image_to_data_url(image)
        image_path = case_dir / f"image_{idx:02d}.png"
        image_path.write_bytes(image_bytes)
        saved_images.append(str(image_path))
        content.append({"type": "image_url", "image_url": {"url": data_url}})
    content.append({"type": "text", "text": case.prompt})

    payload = {
        "model": model,
        "messages": [{"role": "user", "content": content}],
        "max_completion_tokens": max_tokens,
        "temperature": 0.0,
        "stream": False,
    }

    review_payload = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": [
                    *[
                        {"type": "image_file", "image_file": {"path": path}}
                        for path in saved_images
                    ],
                    {"type": "text", "text": case.prompt},
                ],
            }
        ],
        "max_completion_tokens": max_tokens,
        "temperature": 0.0,
        "stream": False,
    }
    write_json(case_dir / "request_for_review.json", review_payload)

    started = time.perf_counter()
    error = ""
    status_code = None
    response_json: dict[str, Any] = {}
    try:
        response = requests.post(
            f"{base_url}/v1/chat/completions",
            json=payload,
            timeout=timeout,
        )
        status_code = response.status_code
        response_json = response.json()
        response.raise_for_status()
    except Exception as exc:  # noqa: BLE001 - preserve the exact request failure.
        error = repr(exc)
        if not response_json:
            response_json = {"error": error}
    latency_s = time.perf_counter() - started
    write_json(case_dir / "response.json", response_json)

    text = response_text(response_json)
    score = score_text(text, case.expected_keywords)
    summary = {
        "case": case.name,
        "prompt": case.prompt,
        "images": saved_images,
        "status_code": status_code,
        "latency_s": latency_s,
        "error": error,
        "generated_text": text,
        **score,
    }
    write_json(case_dir / "summary.json", summary)
    return summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default="8000")
    parser.add_argument("--model", default=os.environ.get("AUDIT_MODEL", DEFAULT_MODEL))
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--timeout", type=float, default=180.0)
    parser.add_argument("--max-tokens", type=int, default=64)
    args = parser.parse_args()

    base_url = f"http://{args.host}:{args.port}"
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    model = args.model or get_default_model(base_url, args.timeout)

    records = []
    for case in make_cases():
        summary = run_case(case, base_url, model, out_dir, args.timeout, args.max_tokens)
        records.append(summary)
        print(
            f"{case.name}: passed={summary['passed']} unable={summary['looks_unable']} "
            f"text={summary['generated_text']!r}"
        )

    with (out_dir / "summary.jsonl").open("w", encoding="utf-8") as f:
        for record in records:
            f.write(json.dumps(record, sort_keys=True) + "\n")
    write_json(
        out_dir / "summary.json",
        {
            "model": model,
            "passed": sum(1 for record in records if record["passed"]),
            "total": len(records),
            "records": records,
        },
    )
    return 0 if all(record["passed"] for record in records) else 1


if __name__ == "__main__":
    raise SystemExit(main())
