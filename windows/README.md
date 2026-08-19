# tukevejtso for Windows

Local Windows command launcher. Run it with:

```cmd
tk
```

Useful direct commands:

```cmd
tk demo
tk password
tk linux
tk cutout INPUT [OUTPUT]
tk transcription
tk enchanted-transcription
tk enhanced-typing
tk openai-key
tk robotics-learning
tk terminal-transparency
tk reboot
tk reboot status
tk reboot toggle
tk reboot disable
tk reboot enable
tk caatuu
tk caatuu local
tk caatuu tunnel
tk caatuu status
tk caatuu verify
tk caatuu stop
tk storage
tk storage start
tk storage rebuild
tk storage status
tk storage stop
```

`tk terminal-transparency` opens a small menu for setting opacity on the current terminal window only. It does not persist opacity to Windows Terminal profiles. In Windows Terminal, tabs and panes in the same window share the window opacity; the tool keeps a private key binding installed so Terminal does not reset opacity after applying it.

`tk password` opens the password manager. It only generates local passwords using Windows/.NET cryptographic randomness and does not save generated passwords. Choose Generate password, enter the length, then select the complexity.

`tk linux` builds and opens the `tukevejtso` Debian utility container. The container is based on `debian:latest`, keeps the repo mounted at `/workspace/tukevejtso`, mounts the cutout Python runtime volume at `/opt/tukevejtso-venvs`, and starts in `/workspace/tukevejtso/linux`. When Docker GPU support is available, newly created containers are created with `--gpus all`; use `tk linux -RecreateForGpu` to replace an older CPU-only container with a GPU-enabled one.

`tk cutout INPUT [OUTPUT]` removes image backgrounds with the Linux cutout engine and writes transparent PNG files. `INPUT` is a Windows folder, and `OUTPUT` defaults to a sibling folder named `<input> - transparent`. Good defaults are BiRefNet, `device=auto` so CUDA is used when the container and PyTorch support it, 1024px model input, alpha floor 24, and alpha ceiling 250. Add `-CleanOutput` to delete the output folder before writing, and `-SaveExtras` only when you want alpha/mask/diagnostic sidecars. Temporary staging under `linux\workspaces\images\cutout-stage` is cleaned automatically after successful copyback. See `..\CUTOUT.md` for usage and deprecated legacy background-removal commands.

`tk transcription` starts the local Whisper transcription agent. The first run downloads the default Whisper model if needed, builds the Rust app with CUDA-enabled Whisper, reads saved settings from `%APPDATA%\tukevejtso\enchanted-transcription-settings.json`, and opens a split terminal view. Defaults are microphone plus system-output capture, English, `ggml-medium.en.bin`, a 12-second rolling Whisper window, and a 70-second transcript fade. Press F9 for persistent settings and a contextual explanation of the selected option, including the default **Silhouette** answer-frame mode and the alternative **Natural Answer** mode. API requests pause after a configurable hidden grace period without stopping capture, local Whisper, or context collection; configurable hidden, idle, and session limits prevent forgotten background sessions from continuing indefinitely. Reaching the configured API-token budget pauses requests and prompts before allowing another equal-sized block, while local context collection continues.

`tk enhanced-typing` starts the separate enhanced typing agent in `agents\enhanced-typing`. Whisper captures from microphone or system output, the OpenAI agent refines completed phrases when intelligence is available, and the tool appends them into an on-screen draft. It uses English by default with `ggml-medium.en.bin`; pass `-Language auto` or another language code to use `ggml-medium.bin`. Press F1 to show the terminal when it is hidden, or flush the draft when the terminal is focused; Ctrl+Alt+F1 is also registered as a backup show shortcut when Windows allows it. Flush mode can copy to clipboard, type into the last target app, or discard the draft. Press F9 for settings; settings pauses listening and lets you change input source, intelligence, flush mode, transparency, and refiner model.

`tk openai-key` stores or updates an OpenAI API key encrypted with Windows DPAPI for tools that need OpenAI access. `tk openai-key -Status` shows whether a key is configured without printing it.

The reboot guard keeps Windows Update enabled, but blocks automatic Windows Update restarts while a user is logged in. Run `tk reboot` for the simple status-and-toggle screen. Changing the guard requires administrator approval.

`tk caatuu` opens a startup menu for the Caatuu workspace at `C:\Work\caatuu`. It can start the local server alone, start it with the shared Cloudflare tunnel, show container and endpoint status, verify the local and active public endpoints, or stop Caatuu while preserving the tunnel used by Minerals. Stopping the shared tunnel is a separate, explicitly warned action. Startup is idempotent, Docker Desktop is started automatically when needed, and each start waits for both container health and the corresponding HTTP endpoint before reporting success. Starting Caatuu also exposes its explicitly versioned Android sideload channel so installed debug-signed builds can check and download updates.

`tk storage` opens a control menu for `C:\Work\storage-and-sharing-services`. It can start or rebuild the Docker service, show its container and HTTP health, print the current local and LAN URLs, or stop it. Starting launches Docker Desktop when needed and waits until the service is ready. The service keeps `restart: "no"`, so it does not start automatically with the computer.

## Layout

- `tk.cmd` is the stable command name.
- `toolkit.cmd` routes direct commands and opens the interactive menu.
- `agents\enchanted-transcription` contains the transcription agent.
- `agents\enhanced-typing` contains the enhanced typing agent.
- `agents\speech-agent-core` contains their shared Rust capture, Whisper, API, and terminal runtime.
- `models\whisper` contains the shared local Whisper model cache used by both agents.
- `tools/*.ps1` contains the real utilities.
- `tools/ui.ps1` contains shared terminal rendering helpers.

## Interface Primitives

The Windows interface layer borrows the useful primitives from `iinuji` while staying native to stock Windows:

- panels for bounded sections
- styled status rows and badges
- small bars and sparklines
- bitmap art text
- PNG rendering from `resources/waajacamaya.png` into terminal half-block cells
