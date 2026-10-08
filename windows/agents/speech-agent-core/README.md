# Shared speech agent core

This crate owns the runtime shared by Enchanted Transcription and Enhanced Typing:

- WASAPI audio capture and source isolation
- rolling local Whisper inference and transcript reconciliation
- OpenAI Responses API transport, optional reference-document grounding, and usage accounting
- terminal/Win32 lifecycle management
- protected restart continuity, session response history, and API pause/exit safeguards
- shared rendering and settings primitives

The product packages are deliberately thin entrypoints:

- `enchanted-transcription` selects the transcription product, persistent F9 settings, insight pane, privacy controls, and API lifecycle safeguards.
- `enhanced-typing` selects the typing product, focus/hotkey behavior, draft flushing, clipboard/type output, and refiner settings.

Product-specific API entrypoints live in `transcription::run_app` and `typing::run_app`. Shared behavior is changed here once rather than copied between both binaries.

Enchanted Transcription keeps complete successful Agent Insights responses in session memory. Up/Down browse older/newer responses on its main screen and pin the selected response while new responses arrive; End restores live following. The pane shows the selected position and the count of newer responses. F5 clears history. Settings and dialog navigation retain their existing controls.

Automatic settings restarts preserve history and its selection in the handoff protected with Windows DPAPI. Changes to answer mode, the selected reference file, or context strictness, and disabling microphone sharing clear history. Independent launches begin with no history.

## Portable logic tests

Install the test dependencies and run the regression suite inside the managed
`tukevejtso` container:

```bash
bash /workspace/tukevejtso/windows/agents/speech-agent-core/setup-tests.sh
bash /workspace/tukevejtso/windows/agents/speech-agent-core/test-logic.sh
```

`setup-tests.sh` installs Debian's `rustc`, `gcc`, and `libc6-dev` packages with
recommended packages disabled. It only configures dependencies inside the
existing container; the root setup and launcher fingerprint remain unchanged.

The suite compiles `speech_logic.rs` and `response_history.rs`, the same
platform-independent modules used by the agents, using only the container's
Rust compiler and standard library. It covers final audio decoding, the F5 audio
cutoff, transcript reconciliation, short replies, forced-update consolidation,
and response history navigation, pinned selection, and live following. Test
binaries live in a temporary container directory and are removed afterward.
Native audio, Whisper inference, and Win32 window behavior require separate
runtime validation.
