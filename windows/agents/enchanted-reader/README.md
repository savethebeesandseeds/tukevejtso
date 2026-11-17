# Enchanted Reader

Native Windows terminal tool that sends one screenshot and an instruction file to the OpenAI Responses API when you press a shortcut.

Enchanted Reader does not transcribe audio and does not build Whisper. It uses the same encrypted OpenAI key as the other agents. Store that key with `tk openai-key`.

## Run

```cmd
tk enchanted-reader
tk reader
```

If the reader asks to connect the terminal, press Enter in that window. In an embedded terminal, Enter opens the reader in its own Windows Console Host. This happens during setup.

Each launch asks five questions. Saved answers are preselected. Up and Down change a choice, Enter continues, and Esc goes back.

1. **Instruction file.** A UTF-8 `.md` file in `instructions`, or a path you type with `P`. The tracked sample is `instructions\example.md`. Other files in that folder are ignored by Git. The limit is 32 KiB. Each capture reads the file again.
2. **Screen portion.** This monitor, a fixed rectangle on the terminal's monitor, or the foreground window at the moment of the shortcut. Enter on the rectangle choice always opens a new drag, and a finished drag replaces the saved one. `C` keeps the saved rectangle without drawing. `R` draws a new one and stays on this question. Cancelling the drag keeps it too. Release the mouse to keep a new rectangle. Right-click or Esc cancels the drag and brings the terminal back. A saved rectangle is cleared when its monitor is gone.
3. **Trigger shortcut.** F8 is registered when the reader starts, with no modifier. Windows does not deliver that key to the window in front. Enter keeps F8. Press another shortcut, release it, then press it again to add it. Letters and digits need Ctrl, Alt, or the Windows key. A function key may be used alone. Windows must accept the shortcut before the tool arms.
4. **Model.** `gpt-5.6-sol`, `gpt-5.6-terra`, or `gpt-5.6-luna`. Terra is the initial default.
5. **Clipboard.** Whether the answer text is copied. The screenshot is never copied or written to disk.

The review screen's Enter saves `%APPDATA%\tukevejtso\enchanted-reader-settings.json` and arms the reader. F8, and any added shortcut, work while another application is in front and do not move focus. Enter captures when the reader terminal is focused. `S` returns to the questions. Up and Down browse earlier answers, Page Up and Page Down scroll the current answer, and End follows the latest answer. Esc quits. F8 is unregistered when the reader exits.

A second shortcut while a capture or request is in flight is ignored. Nothing is sent on a timer. The request uses `store: false`. The instruction file is the task. Text inside the screenshot cannot change the tool's role or output format.

During an armed capture, the reader leaves keyboard focus with the app you are using. A minimized terminal or one outside the selected area stays as it is. If the terminal overlaps the capture, the reader asks Windows to cloak it in place and reveals it before sending the request. If Windows cannot cloak it, minimize the reader or move it outside the capture area and press F8 again. The rectangle picker takes focus during setup.

In foreground-window mode, focus the window you want to read and use the global shortcut. If the reader itself is in front, or the target changes during capture, the reader asks you to try again.
