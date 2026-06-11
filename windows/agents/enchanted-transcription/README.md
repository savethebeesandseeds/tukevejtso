# Enchanted Transcription Agent

Native Windows transcription agent for microphone and system-audio capture with local Whisper inference.

## Run

Use the `tukevejtso` launcher:

```cmd
tk transcription
```

Preferred explicit alias:

```cmd
tk enchanted-transcription
```

The first run downloads the selected model into the shared `windows\models\whisper` cache, builds the Rust terminal app with CUDA-enabled Whisper, reads saved settings from `%APPDATA%\tukevejtso\enchanted-transcription-settings.json`, and opens a split terminal view. If no settings have been saved yet, it starts with microphone plus system-output capture, English, `ggml-medium.en.bin`, a 12-second rolling Whisper window, and a 70-second transcript fade.

The terminal uses a rolling Whisper window rather than waiting for isolated fixed chunks. It refreshes a live hypothesis every few seconds and periodically commits only the new text into the stable transcript pane.

Press F9 during transcription to open settings. Transcript fade changes live with Left/Right. Source selection, language, model, rolling Whisper window, and agent wiring can be changed there and saved for future sessions. When you apply a worker-bound change, the launcher automatically restarts the agent with the saved settings.

Terminal transparency is opt-in through the launcher flags and no longer prompts during normal startup.

The optional right-side agent pane uses the OpenAI Responses API on system-output transcript text. Microphone transcript text is not sent unless enabled in F9 settings. Store the API key once with:

```cmd
tk openai-key
```

The key is encrypted with Windows DPAPI for the current user and stored under `%APPDATA%\tukevejtso\secrets`.

To force CPU mode:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Work\tukevejtso\windows\agents\enchanted-transcription\run.ps1 -Cpu
```

To use a different model:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Work\tukevejtso\windows\agents\enchanted-transcription\run.ps1 -Model medium
```

To choose the language before model selection:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Work\tukevejtso\windows\agents\enchanted-transcription\run.ps1 -Language auto
```

To tune transcript fading, set the fade duration in seconds:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Work\tukevejtso\windows\agents\enchanted-transcription\run.ps1 -FadeSeconds 12
```

To choose the OpenAI agent model:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Work\tukevejtso\windows\agents\enchanted-transcription\run.ps1 -AgentModel gpt-5.4-nano
```

The startup prompt accepts `nano` for `gpt-5.4-nano` and `mini` for `gpt-5.4-mini`. If no key is stored, the launcher asks whether to store one before the transcription agent starts. Use `-SetupOpenAiKey` to force that setup prompt during launch, or `-NoAgent` to skip agent setup completely.

To enable transparency without the prompt:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Work\tukevejtso\windows\agents\enchanted-transcription\run.ps1 -Transparency -TransparencyOpacity 45
```

The same options can be passed through `tukevejtso`:

```cmd
tk transcription -Transparency -TransparencyOpacity 45
```

## Install dependencies

Run from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Work\tukevejtso\windows\agents\enchanted-transcription\install-dependencies.ps1
```

This installs:

- Rustup / Rust toolchain
- Visual Studio Build Tools 2022 with the C++ workload
- CMake
- Ninja
- LLVM / libclang for Rust bindgen
- NVIDIA CUDA Toolkit 12.8

To skip CUDA for a CPU-only setup:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Work\tukevejtso\windows\agents\enchanted-transcription\install-dependencies.ps1 -SkipCuda
```
