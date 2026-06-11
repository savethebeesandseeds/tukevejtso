# Enhanced Typing Agent

Native Windows dictation agent for microphone capture, local Whisper transcription, optional OpenAI cleanup, and clipboard output.

## Run

Use the `tukevejtso` launcher:

```cmd
tk enhanced-typing
```

The first run downloads the selected model into the shared `windows\models\whisper` cache, builds the Rust terminal app with CUDA-enabled Whisper, and starts microphone-only dictation. The default language is English, so the default model is `ggml-medium.en.bin`; pass `-Language auto` or another language code to use `ggml-medium.bin`. When you pause, the completed phrase is sent to OpenAI for cleanup when intelligence is available, then copied to the clipboard only when clipboard output is enabled in settings. The prompt contract lives in `enhanced-typing-agent-instructions.md`.

Store the API key once with:

```cmd
tk openai-key
```

The key is encrypted with Windows DPAPI for the current user and stored under `%APPDATA%\tukevejtso\secrets`.

The display renders only the latest result and a short status line on the bottom terminal row. It asks the terminal window to resize to fit the result with a cap; use Up/Down, PageUp/PageDown, Home, and End to scroll when the result is longer than the cap. The lower bar is `F9 Settings | <state>`, where state is `● hold.`, `● listening...`, or `● thinking...`.

Press F9 to open settings. Settings pauses listening, resizes the terminal to fit the settings view, uses Up/Down to select a row, and uses Left/Right to cycle each editable value with wraparound. The `on`/`off` rows toggle with either side arrow. Transparency includes opaque, clear, and blurry presets; the selected label changes immediately while the slower terminal update runs in the background. The built-in refiner choices are `gpt-5.4-nano`, `gpt-5.4-mini`, and `gpt-5.5`. Esc closes settings; pressing Esc again exits enhanced typing and restores the terminal size and window placement captured at launch. When refinement is off or unavailable, the raw Whisper phrase is used directly.

Enhanced typing remembers settings in `%APPDATA%\tukevejtso\enhanced-typing-settings.json`, including intelligence, clipboard output, transparency, and refiner model. Saved transparency is reapplied on the next enhanced typing launch.

Fullscreen is no longer enabled while the agent is running because it prevents the small fit-to-text window. Enhanced typing snapshots the terminal size and host-window placement before compact resizing, then restores that snapshot from the Rust terminal guard on drop and from a PowerShell `finally` block after the child process returns. Pass `-FullScreen` only if you want the agent to start expanded too.

To force CPU mode:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Work\tukevejtso\windows\agents\enhanced-typing\run.ps1 -Cpu
```

To use a different Whisper model:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Work\tukevejtso\windows\agents\enhanced-typing\run.ps1 -Model medium
```

To choose a non-English or auto-detected language:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Work\tukevejtso\windows\agents\enhanced-typing\run.ps1 -Language auto
```

To choose the OpenAI refiner model:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Work\tukevejtso\windows\agents\enhanced-typing\run.ps1 -AgentModel gpt-5.4-nano
```

The startup prompt accepts `nano` for `gpt-5.4-nano` and `mini` for `gpt-5.4-mini`. Use `-SetupOpenAiKey` to force key setup during launch, or `-NoAgent` to run without OpenAI refinement.

## Install dependencies

Run from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Work\tukevejtso\windows\agents\enhanced-typing\install-dependencies.ps1
```

This installs the same native dependencies as the transcription agent: Rust, Visual Studio Build Tools, CMake, Ninja, LLVM/libclang, and optional CUDA.
