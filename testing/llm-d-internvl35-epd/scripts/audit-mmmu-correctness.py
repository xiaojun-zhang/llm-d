#!/usr/bin/env python3
"""Run fixed MMMU visual multiple-choice probes against an OpenAI endpoint."""

from __future__ import annotations

import argparse
import ast
import base64
import json
import os
import random
import re
import time
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path
from typing import Any

import requests
from datasets import load_dataset
from PIL import Image


DEFAULT_MODEL = "/mnt/weka/data/llm-d-models-pv/hub/models--OpenGVLab--InternVL3_5-30B-A3B/snapshots/main"
DEFAULT_IDS = "validation_Math_1,validation_Math_6,validation_Math_10,validation_Math_11"


@dataclass
class MMMUCase:
    case_id: str
    question: str
    options: list[str]
    answer: str
    image: Image.Image


def parse_options(value: Any) -> list[str]:
    if isinstance(value, list):
        return [str(item) for item in value]
    if isinstance(value, str):
        try:
            parsed = ast.literal_eval(value)
            if isinstance(parsed, list):
                return [str(item) for item in parsed]
        except Exception:
            pass
    return []


def clean_question(question: str) -> str:
    return re.sub(r"<image\s*\d+>", "[image]", question).strip()


def image_to_data_url(image: Image.Image) -> tuple[str, bytes]:
    if image.mode == "RGBA":
        image = image.convert("RGB")
    buf = BytesIO()
    image.save(buf, format="PNG")
    data = buf.getvalue()
    encoded = base64.b64encode(data).decode("ascii")
    return f"data:image/png;base64,{encoded}", data


def load_cases(args: argparse.Namespace) -> list[MMMUCase]:
    dataset = load_dataset(args.dataset, args.config, split=args.split)

    by_id = {row["id"]: row for row in dataset}
    selected_rows = []
    if args.ids:
        for case_id in [item.strip() for item in args.ids.split(",") if item.strip()]:
            if case_id not in by_id:
                raise KeyError(f"MMMU id not found in {args.split}: {case_id}")
            selected_rows.append(by_id[case_id])
    else:
        rows = []
        for row in dataset:
            options = parse_options(row.get("options"))
            if (
                row.get("question_type") == "multiple-choice"
                and row.get("image_1") is not None
                and row.get("answer")
                and options
                and not any("<image" in option.lower() for option in options)
            ):
                rows.append(row)
        if args.sample == "random":
            rng = random.Random(args.seed)
            rng.shuffle(rows)
        selected_rows = rows[: args.num_prompts]

    cases = []
    for row in selected_rows[: args.num_prompts]:
        image = row.get("image_1")
        if image is None or not hasattr(image, "save"):
            continue
        cases.append(
            MMMUCase(
                case_id=row["id"],
                question=clean_question(row.get("question", "")),
                options=parse_options(row.get("options")),
                answer=str(row.get("answer", "")).strip().upper(),
                image=image,
            )
        )
    if not cases:
        raise RuntimeError("No usable MMMU cases selected")
    return cases


def option_lines(options: list[str]) -> str:
    return "\n".join(f"{chr(ord('A') + idx)}. {option}" for idx, option in enumerate(options))


def build_prompt(case: MMMUCase) -> str:
    return (
        "Solve this MMMU multiple-choice question using the image if needed.\n\n"
        f"Question:\n{case.question}\n\n"
        f"Options:\n{option_lines(case.options)}\n\n"
        "Think through the problem, then end with a line exactly like "
        "'Final answer: <letter>'."
    )


def response_text(response_json: dict[str, Any]) -> str:
    choices = response_json.get("choices") or []
    if not choices:
        return ""
    message = choices[0].get("message") or {}
    return (message.get("reasoning_content") or "") + (message.get("content") or "")


def extract_answer(text: str, option_count: int) -> str:
    letters = "".join(chr(ord("A") + idx) for idx in range(option_count))
    upper = text.upper()
    patterns = [
        rf"(?:FINAL\s+)?ANSWER\s*(?:IS|:)?\s*\(?([{letters}])\)?",
        rf"OPTION\s*\(?([{letters}])\)?",
    ]
    for pattern in patterns:
        matches = re.findall(pattern, upper)
        if matches:
            return matches[-1]
    stripped = upper.strip()
    if len(stripped) <= 8 and stripped[:1] in letters:
        return stripped[:1]
    return ""


def write_json(path: Path, payload: Any) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run_case(case: MMMUCase, base_url: str, model: str, out_dir: Path, timeout: float, max_tokens: int) -> dict[str, Any]:
    case_dir = out_dir / case.case_id
    case_dir.mkdir(parents=True, exist_ok=True)

    data_url, image_bytes = image_to_data_url(case.image)
    image_path = case_dir / "image_00.png"
    image_path.write_bytes(image_bytes)

    prompt = build_prompt(case)
    payload = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": data_url}},
                    {"type": "text", "text": prompt},
                ],
            }
        ],
        "max_completion_tokens": max_tokens,
        "temperature": 0.0,
        "stream": False,
    }
    review_payload = {
        "id": case.case_id,
        "model": model,
        "question": case.question,
        "options": case.options,
        "answer": case.answer,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "image_file", "image_file": {"path": str(image_path)}},
                    {"type": "text", "text": prompt},
                ],
            }
        ],
        "max_completion_tokens": max_tokens,
        "temperature": 0.0,
        "stream": False,
    }
    write_json(case_dir / "request_for_review.json", review_payload)

    started = time.perf_counter()
    status_code = None
    error = ""
    response_json: dict[str, Any] = {}
    try:
        response = requests.post(f"{base_url}/v1/chat/completions", json=payload, timeout=timeout)
        status_code = response.status_code
        response_json = response.json()
        response.raise_for_status()
    except Exception as exc:  # noqa: BLE001 - preserve exact request failure.
        error = repr(exc)
        if not response_json:
            response_json = {"error": error}
    latency_s = time.perf_counter() - started
    write_json(case_dir / "response.json", response_json)

    generated_text = response_text(response_json)
    predicted = extract_answer(generated_text, len(case.options))
    summary = {
        "id": case.case_id,
        "question": case.question,
        "options": case.options,
        "answer": case.answer,
        "predicted": predicted,
        "passed": predicted == case.answer,
        "status_code": status_code,
        "error": error,
        "latency_s": latency_s,
        "image": str(image_path),
        "generated_text": generated_text,
    }
    write_json(case_dir / "summary.json", summary)
    return summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default="8000")
    parser.add_argument("--model", default=os.environ.get("AUDIT_MODEL", DEFAULT_MODEL))
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--dataset", default="MMMU/MMMU")
    parser.add_argument("--config", default="Math")
    parser.add_argument("--split", default="validation")
    parser.add_argument("--ids", default=DEFAULT_IDS)
    parser.add_argument("--num-prompts", type=int, default=4)
    parser.add_argument("--sample", choices=("first", "random"), default="first")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--timeout", type=float, default=240.0)
    parser.add_argument("--max-tokens", type=int, default=128)
    args = parser.parse_args()

    base_url = f"http://{args.host}:{args.port}"
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    records = []
    for case in load_cases(args):
        summary = run_case(case, base_url, args.model, out_dir, args.timeout, args.max_tokens)
        records.append(summary)
        print(
            f"{case.case_id}: passed={summary['passed']} "
            f"answer={summary['answer']} predicted={summary['predicted']} "
            f"text={summary['generated_text']!r}"
        )

    with (out_dir / "summary.jsonl").open("w", encoding="utf-8") as f:
        for record in records:
            f.write(json.dumps(record, sort_keys=True) + "\n")
    write_json(
        out_dir / "summary.json",
        {
            "dataset": args.dataset,
            "config": args.config,
            "split": args.split,
            "model": args.model,
            "passed": sum(1 for record in records if record["passed"]),
            "total": len(records),
            "records": records,
        },
    )
    return 0 if all(record["passed"] for record in records) else 1


if __name__ == "__main__":
    raise SystemExit(main())
