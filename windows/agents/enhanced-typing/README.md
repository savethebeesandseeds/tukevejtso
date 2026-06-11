# Enhanced Typing Agent

Native Windows dictation agent for microphone or system-output capture, local Whisper transcription, optional OpenAI cleanup, and explicit draft flushing.

## Run

Use the `tukevejtso` launcher:

```cmd
tk enhanced-typing
```

The first run downloads the selected model into the shared `windows\models\whisper` cache, builds the Rust terminal app with CUDA-enabled Whisper, and starts dictation from the selected input source. The default input is microphone; F9 settings can switch to system output. The default language is English, so the default model is `ggml-medium.en.bin`; pass `-Language auto` or another language code to use `ggml-medium.bin`. When you pause, the completed phrase is sent to OpenAI for cleanup when intelligence is available, then appended to the on-screen draft. The prompt contract lives in `enhanced-typing-agent-instructions.md`.

Store the API key once with:

```cmd
tk openai-key
```

The key is encrypted with Windows DPAPI for the current user and stored under `%APPDATA%\tukevejtso\secrets`.

The display renders the accumulated draft and a short status line on the bottom terminal row. It asks the terminal window to resize to fit the draft with a cap; use Up/Down, PageUp/PageDown, Home, and End to scroll when the draft is longer than the cap. The lower bar is `F1 Flush/Show | Esc Clear | F9 Settings | requests N | <state>`, where state is `hold.`, `listening...`, or `thinking...`. The request counter tracks OpenAI refiner requests. When the terminal is not focused, enhanced typing stays on hold. Global F1 brings the captured terminal window back to the foreground; Ctrl+Alt+F1 is also registered as a backup show shortcut when Windows allows it. Focused F1 flushes the draft and hides the terminal after a successful flush. Focused Esc clears the draft; when the draft is already empty, Esc asks for confirmation and a second Esc exits.

Press F9 to open settings. Settings pauses listening, resizes the terminal to fit the settings view, uses Up/Down to select a row, and uses Left/Right to cycle each editable value with wraparound. The `on`/`off` rows toggle with either side arrow. Flush mode switches between `clipboard`, `type`, and `discard`: clipboard copies and clears the draft, type minimizes the terminal and sends the draft as paced Windows keystrokes to the last non-terminal target window, and discard clears the draft without output. Typing speed changes the type-mode keystroke delay. Input switches between microphone and system output. Transparency includes opaque, clear, and blurry presets; the selected label changes immediately while the slower terminal update runs in the background. The built-in refiner choices are `gpt-5.4-nano`, `gpt-5.4-mini`, and `gpt-5.5`. Esc closes settings; outside settings, Esc clears content before it can exit. When refinement is off or unavailable, the raw Whisper phrase is used directly.

Enhanced typing remembers settings in `%APPDATA%\tukevejtso\enhanced-typing-settings.json`, including intelligence, flush mode, typing speed, input source, transparency, and refiner model. Saved transparency is reapplied on the next enhanced typing launch.

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

Use `-SetupOpenAiKey` to force key setup during launch, or `-NoAgent` to run without OpenAI refinement.

## Install dependencies

Run from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Work\tukevejtso\windows\agents\enhanced-typing\install-dependencies.ps1
```

This installs the same native dependencies as the transcription agent: Rust, Visual Studio Build Tools, CMake, Ninja, LLVM/libclang, and optional CUDA.
