# Parakeet Dictation

Menu-bar dictation for Apple silicon Macs. Press the right Command and right Option keys to start, speak, and press them again to type the transcript into the focused app.

Speech is transcribed on this Mac with [Cohere Transcribe 03-2026](https://huggingface.co/spokedotso/cohere-transcribe-03-2026-mlx-4bit), 4-bit MLX. Nothing is sent to a server.

## Use it

- Press right Command and right Option once to start. Press them again to finish.
- Escape cancels the take.
- A take longer than about 20 seconds is transcribed while you are still talking. The rest is finished when you stop, then the whole transcript is pasted once.
- The menu has Copy Last Text, recent recordings, and a vocabulary file. A line in the vocabulary file keeps that spelling. A line like `heard phrase -> Snapdragon 8 Elite Gen 5` replaces that phrase. It does not teach the model the sound.
- The model loads on the first transcription and unloads after 3 idle minutes.
- The Mac’s built-in microphone is selected as the system input, including when Bluetooth earbuds are connected.

Recordings are kept in `~/Library/Application Support/Parakeet Dictation/Recordings`.

## Set up

Requires an Apple silicon Mac and Python 3.13 or newer.

```bash
python3 -m venv .venv-cohere
.venv-cohere/bin/pip install -r requirements.txt
.venv-cohere/bin/python -c 'from huggingface_hub import snapshot_download; snapshot_download("spokedotso/cohere-transcribe-03-2026-mlx-4bit", local_dir="models/cohere-transcribe-4bit")'
chmod +x build dictate transcribe
./build
./dictate
```

After building, allow the app under System Settings → Privacy & Security → Device Control and Data Access, and allow the microphone. Rebuilding changes the app signature, so that switch has to be turned off and on again.

`./transcribe some-audio.wav` transcribes a file from the terminal.
