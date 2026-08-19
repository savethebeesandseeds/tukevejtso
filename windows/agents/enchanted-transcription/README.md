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

Press F9 during transcription to open settings. The option list is on the left, details and choices for the selected option are on the right, and recent errors plus live agent diagnostics appear below. Transcript fade and API lifecycle controls apply without restarting. Source selection, language, model, rolling Whisper window, and agent wiring are saved and automatically restart the worker when required.

The persistent **Answer mode** setting offers two right-pane response styles. **Silhouette** is the default and returns a content-free spoken-answer frame with `...` blanks for the user's own knowledge. **Natural Answer** returns a concise, directly usable answer to the latest question while stating uncertainty instead of inventing missing facts. Changing the mode uses the normal brief automatic application restart to rebuild the response contract.

The insight agent has layered API safeguards. By default, new API requests pause after the terminal has remained hidden, minimized, or cloaked for 15 seconds; F9 can select a different grace period or turn the rule off. Audio capture, local Whisper inference, rolling transcript history, and agent context continue while paused. Only API submission is held, and resuming uses the newest consolidated context without replaying a request backlog. If the terminal window cannot be identified, requests remain enabled and F9 records a visible warning instead of silently blocking Agent Insights. The application exits after 15 minutes continuously hidden, 30 minutes without transcript activity, or a four-hour session. At 100,000 reported API tokens, new insight requests pause and the terminal asks before granting another 100,000-token block. Declining leaves only the API paused; F1 reopens the prompt. F9 can change or disable each limit.

Terminal transparency is opt-in through the launcher flags and no longer prompts during normal startup.

The optional right-side agent pane uses the OpenAI Responses API on system-output transcript text. Microphone transcript text is not sent unless enabled in F9 settings. Store the API key once with:

```cmd
tk openai-key
```

The key is encrypted with Windows DPAPI for the current user and stored under `%APPDATA%\tukevejtso\secrets`.

Enchanted Transcription and Enhanced Typing are separate thin binaries over `..\speech-agent-core`. Shared capture, Whisper, transcript reconciliation, API transport, and terminal lifecycle behavior is implemented once in that crate; product-specific entrypoints select the transcription or typing experience.

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
