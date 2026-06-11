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

`tk transcription` starts the local Whisper transcription agent. The first run downloads the default Whisper model if needed, builds the Rust app with CUDA-enabled Whisper, prompts for language plus microphone/system audio sources, and opens a split terminal view. The default model family is medium: English uses `ggml-medium.en.bin`, while `auto` and non-English language codes use `ggml-medium.bin`. Press F9 during transcription for settings; the stable startup prompts remain in place, transcript fade adjusts live, and worker-bound choices can be staged for restart.

`tk enhanced-typing` starts the separate enhanced typing agent in `agents\enhanced-typing`. Whisper captures a spoken phrase, the OpenAI agent refines it into insertable text when intelligence is available, and the tool can copy the result to the clipboard when clipboard output is enabled. It uses English by default with `ggml-medium.en.bin`; pass `-Language auto` or another language code to use `ggml-medium.bin`. The display shows only the latest result with a compact status line, asks the terminal window to resize to the result with a cap, and supports Up/Down scrolling for long text. Press F9 for settings; settings pauses listening, shows startup details, and lets you toggle intelligence and clipboard output.

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
