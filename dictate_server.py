#!/usr/bin/env python3
"""Long-running Cohere Transcribe worker.

The menu-bar app sends one JSON object per line on stdin:
    {"wav": "/path/to/audio.wav"}
and reads one JSON object per line on stdout:
    {"text": "..."} or {"error": "..."}

The model stays unloaded until a recording arrives, and is released after a
few idle minutes. MLX otherwise keeps a free-buffer cache as large as the
GPU working set, which is what pushed this process to 13–15 GB.
"""

from __future__ import annotations

import gc
import json
import os
import re
import select
import sys
import time

import mlx.core as mx
import numpy as np
import soundfile as sf
from mlx_speech.generation import CohereAsrModel

_protocol = None

ROOT = os.path.dirname(os.path.abspath(__file__))
MODEL = os.environ.get(
    "COHERE_MODEL",
    os.path.join(ROOT, "models", "cohere-transcribe-4bit"),
)
VOCABULARY = os.environ.get("COHERE_VOCABULARY", "")
IDLE_UNLOAD_SECONDS = 180
CACHE_LIMIT = 256 * 1024 * 1024

speech: CohereAsrModel | None = None
last_used = 0.0


def reply(payload: dict) -> None:
    if _protocol is None:
        raise RuntimeError("protocol stream is not open")
    _protocol.write(json.dumps(payload) + "\n")
    _protocol.flush()


def configure_memory() -> None:
    mx.set_cache_limit(CACHE_LIMIT)


def release_memory() -> None:
    gc.collect()
    mx.clear_cache()


def memory_report() -> str:
    active = mx.get_active_memory()
    cache = mx.get_cache_memory()
    return f"memory active {active / 1_000_000:.0f}MB cache {cache / 1_000_000:.0f}MB"


def unload() -> None:
    global speech
    speech = None
    release_memory()
    print(f"unloaded {memory_report()}", file=sys.stderr)


def ensure_model() -> CohereAsrModel:
    global speech
    if speech is None:
        print("loading model", file=sys.stderr)
        speech = CohereAsrModel.from_path(MODEL)
        print(f"loaded {memory_report()}", file=sys.stderr)
    return speech


def load_audio(path: str) -> np.ndarray:
    audio, sample_rate = sf.read(path, dtype="float32", always_2d=False)
    audio = np.asarray(audio, dtype=np.float32)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    audio = np.ascontiguousarray(audio, dtype=np.float32)
    if int(sample_rate) == 16000:
        return audio
    if audio.size == 0:
        return audio
    duration = audio.shape[0] / float(sample_rate)
    count = max(1, int(round(duration * 16000)))
    source = np.linspace(0.0, 1.0, num=audio.shape[0], endpoint=False)
    target = np.linspace(0.0, 1.0, num=count, endpoint=False)
    return np.interp(target, source, audio).astype(np.float32)


def drop_hallucination(text: str) -> str:
    """Throw away silence loops such as a sentence repeated for a whole pause."""
    cleaned = " ".join(text.split())
    if not cleaned:
        return ""
    sentences = re.split(r"(?<=[.!?])\s+", cleaned)
    counts: dict[str, int] = {}
    for sentence in sentences:
        key = sentence.strip().lower()
        if len(key) >= 40:
            counts[key] = counts.get(key, 0) + 1
    repeated = {key for key, count in counts.items() if count >= 2}
    if repeated:
        kept = [sentence for sentence in sentences if sentence.strip().lower() not in repeated]
        cleaned = " ".join(part.strip() for part in kept if part.strip())
    words = cleaned.split()
    if len(words) >= 24:
        unique = len({word.lower().strip(".,!?;:\"'") for word in words})
        if unique / len(words) < 0.28:
            return ""
    return cleaned


def apply_vocabulary(text: str) -> str:
    if not VOCABULARY or not os.path.isfile(VOCABULARY):
        return text
    with open(VOCABULARY, encoding="utf-8") as handle:
        lines = handle.readlines()
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "->" in line:
            source, destination = [part.strip() for part in line.split("->", 1)]
            if source:
                text = re.sub(re.escape(source), destination, text, flags=re.IGNORECASE)
        else:
            text = re.sub(re.escape(line), line, text, flags=re.IGNORECASE)
    return text


def transcribe(path: str) -> str:
    audio = load_audio(path)
    try:
        result = ensure_model().transcribe(
            audio,
            sample_rate=16000,
            language="en",
            punctuation=True,
            itn=True,
        )
        return drop_hallucination(apply_vocabulary(str(result.text or "").strip()))
    finally:
        del audio
        release_memory()
        print(memory_report(), file=sys.stderr)


def maybe_unload() -> None:
    if speech is None:
        return
    if time.monotonic() - last_used < IDLE_UNLOAD_SECONDS:
        return
    unload()
    reply({"loaded": False})


def main() -> int:
    global last_used, _protocol
    _protocol = os.fdopen(os.dup(sys.stdout.fileno()), "w", buffering=1, closefd=True)
    sys.stdout = sys.stderr
    if not os.path.isdir(MODEL):
        reply({"error": f"model folder is missing: {MODEL}"})
        return 1
    configure_memory()
    reply({"ready": True, "loaded": False})
    while True:
        timeout = 30.0
        if speech is not None:
            remaining = IDLE_UNLOAD_SECONDS - (time.monotonic() - last_used)
            timeout = max(1.0, min(30.0, remaining))
        readable, _, _ = select.select([sys.stdin], [], [], timeout)
        if not readable:
            maybe_unload()
            continue
        line = sys.stdin.readline()
        if line == "":
            break
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError as exc:
            reply({"error": f"bad request: {exc}"})
            continue
        command = request.get("cmd")
        if command == "quit":
            break
        if command == "unload":
            unload()
            reply({"loaded": False})
            continue
        path = request.get("wav")
        if not path:
            reply({"error": "missing wav path"})
            continue
        last_used = time.monotonic()
        try:
            reply({"text": transcribe(path)})
        except Exception as exc:
            release_memory()
            reply({"error": str(exc)})
        last_used = time.monotonic()
    unload()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit(0)
    except KeyboardInterrupt:
        raise SystemExit(0)
