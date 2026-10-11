---
library_name: mlx-speech
license: apache-2.0
base_model:
- CohereLabs/cohere-transcribe-03-2026
tags:
- mlx
- mlx-speech
- cohere
- asr
- speech-recognition
- speech-to-text
- stt
pipeline_tag: automatic-speech-recognition
---

# spokedotso/cohere-transcribe-03-2026-mlx-4bit

A 4-bit MLX quantization of [CohereLabs/cohere-transcribe-03-2026](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026), hosted by **Spoke** for on-device speech-to-text on Apple Silicon.

Derived from the native mlx-speech conversion ([mlx-community/cohere-transcribe-03-2026-mlx-8bit](https://huggingface.co/mlx-community/cohere-transcribe-03-2026-mlx-8bit), maintained by [appautomaton](https://huggingface.co/appautomaton/cohere-asr-mlx)) by dequantizing the int8 weights and re-quantizing to 4-bit (affine, group size 64) with mlx-speech's own quantizer. Loads via the [mlx-speech](https://github.com/appautomaton/mlx-speech) library (Python 3.13+), not stock mlx-audio.

## Why this exists

On Spoke's internal LibriSpeech test-clean benchmark (250 samples), this 4-bit build measured 1.28% WER at 0.05x real-time factor with a 1.89 GB peak memory footprint, beating the previously shipped 4-bit Whisper turbo (2.66% WER) on accuracy and speed while staying under a 2 GB memory budget.

## Usage

```python
import numpy as np, soundfile as sf
from mlx_speech.generation import CohereAsrModel

audio, sr = sf.read("input.wav", dtype="float32", always_2d=False)
if audio.ndim > 1:
    audio = audio.mean(axis=1)
# resample to 16 kHz first if sr != 16000

model = CohereAsrModel.from_path("path/to/this/repo")
print(model.transcribe(audio, sample_rate=16000, language="en").text)
```
