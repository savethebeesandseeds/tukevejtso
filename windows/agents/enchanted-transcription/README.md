# Enchanted Transcription

Native Windows transcription for microphone and system audio, using local Whisper inference with an optional OpenAI-powered Agent Insights pane.

## Start

Use either launcher alias:

```cmd
tk transcription
tk enchanted-transcription
```

The first run builds the Rust terminal application and downloads the selected Whisper model into the shared `windows\models\whisper` cache. Saved settings live at `%APPDATA%\tukevejtso\enchanted-transcription-settings.json`.

With no saved settings, the application starts with microphone plus system-output capture, English, `ggml-medium.en.bin`, a 12-second rolling Whisper window, a 70-second transcript fade, and Agent Insights enabled when an API key is available.

Store or update the API key before using Agent Insights:

```cmd
tk openai-key
```

The key is encrypted with Windows DPAPI for the current user and stored under `%APPDATA%\tukevejtso\secrets`. Without a usable key, local transcription still works and F9 reports that Agent Insights is unavailable.

## Main controls

| Key | Action |
| --- | --- |
| F1 | Request an immediate Agent Insights update. When the token budget is paused, reopen its continuation prompt. |
| F5 | Clear the current transcript and Agent Insights state. Lifetime request and token counters remain visible. |
| F9 | Open persistent settings, details, choices, status, warnings, and recent errors. |
| Q, Esc, or Ctrl+C | Exit from the main screen. |

Inside F9, use Up/Down to select a setting and Left/Right to change it. F9 or Esc closes the settings list; if values changed, choose Apply or Discard. Page Up, Page Down, Home, and End scroll long settings and diagnostics views.

## Transcription and Agent Insights

The terminal maintains rolling Whisper hypotheses instead of treating each audio interval as an isolated clip. Stable transcript text is reconciled locally and retained as context.

Automatic Agent Insights updates wait for about 1.2 seconds of silence after new text in an Agent-shared audio source instead of issuing requests continuously while speech is active. Updates are consolidated, rate-limited, and based on the newest context; F1 can request an update manually. Agent Insights requires system-output capture, an enabled agent, and a stored API key.

Both Silhouette and Natural Answer modes also show a bounded list of the main risks supported by the current conversation or selected reference context.

The Responses API requests use `store: false`. System-output transcript text is included when Agent Insights runs. Microphone transcript text remains local unless **Mic context** is enabled in F9.

### Spanish transcription

Choose **Language: Spanish (es)** and **Whisper model: medium** in F9. Whisper's `medium` model is multilingual and is the Spanish-capable counterpart to the English-only `medium.en`; there is no separate `medium.es` model. When Spanish or another non-English language is selected, the application automatically replaces a standard `.en` model with its multilingual counterpart. The launcher downloads `ggml-medium.bin` on first use.

Language and Whisper model are session choices. Each independent launch starts in English with `medium.en`; an F9 worker restart keeps the choices made during the current session. Explicit `-Language` and `-Model` launch options still override these defaults.

The model list follows the global language setting: English shows the four standard `.en` models, while Auto, Spanish, and other languages show the four standard multilingual models. This removes duplicate English choices. To add another whisper.cpp model, place a regular file named `ggml-<model-name>.bin` directly in `windows\models\whisper` and reopen F9. Detected models are added to the list; custom models carrying the English-only `.en` marker are offered only for English. Built-in models retain automatic downloads, while custom models must already exist in the folder.

### Answer modes

- **Silhouette** is the default. It returns a short, content-free spoken-answer frame with `...` blanks for the user's own knowledge.
- **Natural Answer** returns a concise, directly usable answer to the latest question and states uncertainty instead of inventing missing facts.

Changing the answer mode restarts the agent wiring, clears answer content derived from the previous mode, and requests a fresh update.

## Reference context

Place private UTF-8 `.md`, `.txt`, `.json`, or `.csv` files in `contexts`, beside the tracked `contexts\example.md`. F9 discovers files directly inside that folder and exposes two settings:

- **Reference context** selects one file or **None**.
- **Context strictness** controls how the selected file guides the answer:
    - **Soft** uses it as helpful background while allowing transcript evidence and reliable general knowledge.
    - **Strong** treats it as authoritative factual grounding, avoids outside facts, and states when the available context is insufficient.

The selected file is loaded fresh and sent in full with every Agent Insights request. Editing it takes effect on the next request without another restart. Context-file selection is session-only and returns to **None** on every independent launch; F9 worker restarts preserve it within the current session. Context strictness remains persistent. Files are limited to 32 KiB, both to bound API cost and to prevent accidentally selecting a large export. Missing, empty, unreadable, non-UTF-8, symbolic-link, or oversized files stop before the API call and produce an F9 error.

Changing the selected file or strictness clears Agent results derived under the old context and requests a fresh update. Document content is sent as untrusted user data; a higher-priority developer policy tells the model never to treat instructions inside the document as prompt instructions. Private context files are ignored by Git, and only `example.md` is tracked. This is lightweight whole-document grounding, not chunked retrieval or full RAG.

## F9 settings

| Group | Settings | Application behavior |
| --- | --- | --- |
| Transcription | Transcript fade | Applies immediately. |
| Transcription | Sources, Whisper window | Persistent and applied through an automatic worker restart. |
| Transcription | Language, Whisper model | Session-only; defaults to English with `medium.en` on a fresh launch and survives automatic worker restarts. |
| Agent | Agent on/off, Agent model, Answer mode, Mic context, Context strictness | Persistent and applied through an automatic worker restart. |
| Agent | Reference context | Session-only; defaults to **None** on a fresh launch and survives automatic worker restarts. |
| API safeguards | Hidden API pause, hidden exit, idle exit, maximum session, token budget | Applies without restarting capture. |
| Appearance | Transparency | Applies immediately through the existing terminal-transparency tool. |

Settings that require a restart first prevent new requests, wait for any in-flight request so its usage can be counted, and then restart automatically. Visible transcripts, Agent context, errors, lifecycle timers, and usage counters survive through a launcher-scoped restart state protected with Windows DPAPI. The reference document itself is not copied into that state.

## API and background safeguards

Defaults are designed to limit forgotten background sessions and unexpected token use:

- New API requests pause after the terminal has not been the foreground window for 15 seconds.
- Local audio capture, Whisper inference, transcript history, and context collection continue while API requests are paused.
- If terminal visibility cannot be monitored, requests pause immediately and F9 shows a warning. Monitoring recovery resumes from the newest consolidated context without replaying a backlog.
- The application exits after 15 minutes out of view, 30 minutes without transcript activity, or four hours of total session time.
- At 100,000 reported API tokens, requests pause and require confirmation before granting another block of the same size. Declining keeps the API paused; F1 reopens the prompt.

Every safeguard can be changed or disabled in F9. Turning Agent Insights off stops remote requests without stopping local transcription.

## Local data and privacy

Plaintext transcript dumps are disabled by default. Enable them only for local debugging with `-TranscriptDump` or `TUKEVEJTSO_TRANSCRIPT_DUMP=1`; enabled dumps use the existing seven-day cleanup policy.

The launcher restores any pre-existing `OPENAI_API_KEY` and `TUKEVEJTSO_TRANSCRIPT_DUMP` environment values when it exits. The client sets `store: false` on every request, but selected transcript and reference-context content still leaves the computer as request input whenever Agent Insights is enabled.

## Launcher options

Options passed through `tk transcription` override saved values for the initial worker. After F9 saves settings, the saved values become authoritative for the automatic restart.

| Option | Purpose |
| --- | --- |
| `-Cpu` | Build and run without the CUDA feature. |
| `-Model <name>` | Select a built-in model or an installed `ggml-<name>.bin` model detected in the shared cache. |
| `-Language <code>` | Use a language code or `auto`; English defaults to an `.en` model. |
| `-FadeSeconds <5-180>` | Override transcript fading for this launch. |
| `-AgentModel <id>` | Override the OpenAI model ID. |
| `-NoAgent` | Start with Agent Insights disabled. |
| `-SetupOpenAiKey` | Run the API-key setup during launch. |
| `-TranscriptDump` | Opt in to local plaintext transcript dumps. |
| `-Transparency` | Apply a one-session transparency override; combine with `-TransparencyOpacity` and `-TransparencyBackground`. |
| `-FullScreen` | Maximize the terminal for this launch. |

Example:

```cmd
tk transcription -Cpu -Language auto -Model medium
tk transcription -Language es -Model medium
```

For direct PowerShell use from this directory:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\run.ps1 -Cpu
```

## Install dependencies

From this directory, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-dependencies.ps1
```

The installer provides Rustup, Visual Studio Build Tools 2022 with the C++ workload, CMake, Ninja, LLVM/libclang, and NVIDIA CUDA Toolkit 12.8. For a CPU-only setup:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-dependencies.ps1 -SkipCuda
```

Enchanted Transcription and Enhanced Typing are thin binaries over `..\speech-agent-core`. Shared capture, Whisper, transcript reconciliation, API transport, rendering, and lifecycle behavior are implemented in that crate.
