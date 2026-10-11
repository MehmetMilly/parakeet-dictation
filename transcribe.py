#!/usr/bin/env python3
"""Transcribe one audio file with the local Cohere model."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import mlx.core as mx
from mlx_speech.generation import CohereAsrModel

import dictate_server


def main() -> int:
    parser = argparse.ArgumentParser(description="Transcribe audio with local Cohere Transcribe.")
    parser.add_argument("audio", help="Path to an audio file")
    args = parser.parse_args()
    model_dir = Path(__file__).resolve().parent / "models" / "cohere-transcribe-4bit"
    if not model_dir.is_dir():
        print(f"Model folder is missing: {model_dir}", file=sys.stderr)
        return 1
    dictate_server.configure_memory()
    speech = CohereAsrModel.from_path(model_dir)
    text = dictate_server.drop_hallucination(
        dictate_server.apply_vocabulary(
            speech.transcribe(
                dictate_server.load_audio(args.audio),
                sample_rate=16000,
                language="en",
                punctuation=True,
                itn=True,
            ).text
        )
    )
    mx.clear_cache()
    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
