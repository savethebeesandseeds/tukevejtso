# Shared speech agent core

This crate owns the runtime shared by Enchanted Transcription and Enhanced Typing:

- WASAPI audio capture and source isolation
- rolling local Whisper inference and transcript reconciliation
- OpenAI Responses API transport and usage accounting
- terminal/Win32 lifecycle management
- shared rendering and settings primitives

The product packages are deliberately thin entrypoints:

- `enchanted-transcription` selects the transcription product, persistent F9 settings, insight pane, privacy controls, and API lifecycle safeguards.
- `enhanced-typing` selects the typing product, focus/hotkey behavior, draft flushing, clipboard/type output, and refiner settings.

Product-specific API entrypoints live in `transcription::run_app` and `typing::run_app`. Shared behavior is changed here once rather than copied between both binaries.
