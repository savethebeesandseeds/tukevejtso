# tukevejtso for Windows

Local Windows command launcher. Run it with:

```cmd
tk
```

Useful direct commands:

```cmd
tk demo
tk password
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
```

`tk terminal-transparency` opens a small menu for setting opacity on the current terminal window only. It does not persist opacity to Windows Terminal profiles. In Windows Terminal, tabs and panes in the same window share the window opacity; the tool keeps a private key binding installed so Terminal does not reset opacity after applying it.

`tk password` opens the password manager. It only generates local passwords using Windows/.NET cryptographic randomness and does not save generated passwords. Choose Generate password, enter the length, then select the complexity.

`tk transcription` starts the local Whisper transcription agent. The first run downloads the default Whisper model if needed, builds the Rust app with CUDA-enabled Whisper, reads saved settings from `%APPDATA%\tukevejtso\enchanted-transcription-settings.json`, and opens a split terminal view. Defaults are microphone plus system-output capture, English, `ggml-medium.en.bin`, a 12-second rolling Whisper window, and a 70-second transcript fade. Press F9 during transcription for persistent settings; applying worker-bound changes automatically restarts the agent.

`tk enhanced-typing` starts the separate enhanced typing agent in `agents\enhanced-typing`. Whisper captures from microphone or system output, the OpenAI agent refines completed phrases when intelligence is available, and the tool appends them into an on-screen draft. It uses English by default with `ggml-medium.en.bin`; pass `-Language auto` or another language code to use `ggml-medium.bin`. Press F1 to show the terminal when it is hidden, or flush the draft when the terminal is focused; Ctrl+Alt+F1 is also registered as a backup show shortcut when Windows allows it. Flush mode can copy to clipboard, type into the last target app, or discard the draft. Press F9 for settings; settings pauses listening and lets you change input source, intelligence, flush mode, transparency, and refiner model.

`tk openai-key` stores or updates an OpenAI API key encrypted with Windows DPAPI for tools that need OpenAI access. `tk openai-key -Status` shows whether a key is configured without printing it.

The reboot guard keeps Windows Update enabled, but blocks automatic Windows Update restarts while a user is logged in. Run `tk reboot` for the simple status-and-toggle screen. Changing the guard requires administrator approval.

## Layout

- `tk.cmd` is the stable command name.
- `toolkit.cmd` routes direct commands and opens the interactive menu.
- `agents\enchanted-transcription` contains the transcription agent.
- `agents\enhanced-typing` contains the enhanced typing agent.
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
