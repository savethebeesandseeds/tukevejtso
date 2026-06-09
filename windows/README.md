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
tk openai-key
tk robotics-learning
tk terminal-transparency
tk reboot
tk reboot status
tk reboot toggle
tk reboot disable
tk reboot enable
```

`tk terminal-transparency` opens a small menu for setting opacity and background mode on a dedicated transparent terminal profile.

`tk password` opens the password manager. It only generates local passwords using Windows/.NET cryptographic randomness and does not save generated passwords. Choose Generate password, enter the length, then select the complexity.

`tk transcription` starts the local Whisper transcription agent. The first run downloads the default Whisper model if needed, builds the Rust app with CUDA-enabled Whisper, prompts for microphone/system audio sources, and opens a split terminal view.

`tk openai-key` stores or updates an OpenAI API key encrypted with Windows DPAPI for tools that need OpenAI access. `tk openai-key -Status` shows whether a key is configured without printing it.

The reboot guard keeps Windows Update enabled, but blocks automatic Windows Update restarts while a user is logged in. Run `tk reboot` for the simple status-and-toggle screen. Changing the guard requires administrator approval.

## Layout

- `tk.cmd` is the stable command name.
- `toolkit.cmd` routes direct commands and opens the interactive menu.
- `tools/*.ps1` contains the real utilities.
- `tools/ui.ps1` contains shared terminal rendering helpers.

## Interface Primitives

The Windows interface layer borrows the useful primitives from `iinuji` while staying native to stock Windows:

- panels for bounded sections
- styled status rows and badges
- small bars and sparklines
- bitmap art text
- PNG rendering from `resources/waajacamaya.png` into terminal half-block cells
