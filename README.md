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

## Install

Download **Parakeet Dictation.dmg** from the [latest release](https://github.com/MehmetMilly/parakeet-dictation/releases/latest). Open it and drag the **Parakeet Dictation** folder into Applications. The folder has to stay together: the app and the `Runtime` folder next to it, which contains Python and the Cohere model.

Right-click the app and choose Open the first time. macOS asks for that because the app is not notarized with Apple. Allow the microphone, and allow the app under System Settings → Privacy & Security → Device Control and Data Access so it can type into other apps.

## Set up from source

Requires an Apple silicon Mac, Python 3.13 or newer, and Git LFS. The Cohere weights in `models/cohere-transcribe-4bit` are the Apache-2.0 4-bit build from [spokedotso/cohere-transcribe-03-2026-mlx-4bit](https://huggingface.co/spokedotso/cohere-transcribe-03-2026-mlx-4bit), derived from CohereLabs/cohere-transcribe-03-2026.

```bash
git lfs install
git clone https://github.com/MehmetMilly/parakeet-dictation.git
cd parakeet-dictation
python3 -m venv .venv-cohere
.venv-cohere/bin/pip install -r requirements.txt
chmod +x build dictate transcribe
./build
./dictate
```

After building, allow the app under System Settings → Privacy & Security → Device Control and Data Access, and allow the microphone. Rebuilding changes the app signature, so that switch has to be turned off and on again.

`./transcribe some-audio.wav` transcribes a file from the terminal.
