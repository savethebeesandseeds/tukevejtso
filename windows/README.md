# tukevejtso for Windows

Local Windows command launcher. Run it with:

```cmd
tk
```

The menu groups tools into Files & media, Voice & text, Containers & services,
System & security, and Help & demos. A description below the list explains the
highlighted tool. Use Up/Down to move, Enter to open, a tool's number to jump,
Home/End to reach the first or last tool, and Q/Esc to quit. The list scrolls
inside its panel when needed, with arrows in the borders; the parrot appears
alongside it when the terminal is wide enough.

Useful direct commands:

```cmd
tk demo
tk password
tk linux
tk cutout INPUT [OUTPUT]
tk join-pdfs
tk join-pdfs "C:\Work\documents" -Recursive
tk compress-pdf
tk compress-pdf "C:\Work\documents\report.pdf" -Preset Balanced
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

`tk join-pdfs` opens the Windows folder picker, then the terminal PDF joiner. Choose a folder, browse its PDFs in a folder tree, select files, arrange their order, and review the result before merging. Subfolders are included by default. The previous folder is the picker's starting view; confirming that folder restores its selection. See [PDF joiner](#pdf-joiner) below for controls and setup.

`tk linux` opens the directly managed `tukevejtso` Debian utility container. It uses the already-local `debian:latest` image and the repository's dependency-only `setup.sh`; there is no project Dockerfile or Compose file. The repo is mounted at `/workspace/tukevejtso`, while the existing `tukevejtso-cutout-venvs` volume is reattached without copying at `/opt/tukevejtso-venvs`. Normal startup reuses stopped containers, refuses missing or mismatched persistent state, and never replaces a container automatically. Newly created containers receive GPU access when read-only host and Docker runtime checks find NVIDIA support.

`tk cutout INPUT [OUTPUT]` removes image backgrounds with the Linux cutout engine and writes transparent PNG files. `INPUT` is a Windows folder, and `OUTPUT` defaults to a sibling folder named `<input> - transparent`. Good defaults are BiRefNet, `device=auto` so CUDA is used when the container and PyTorch support it, 1024px model input, alpha floor 24, and alpha ceiling 250. Add `-CleanOutput` to delete the output folder before writing, and `-SaveExtras` only when you want alpha/mask/diagnostic sidecars. Temporary staging under `linux\workspaces\images\cutout-stage` is cleaned automatically after successful copyback. See `..\CUTOUT.md` for usage and deprecated legacy background-removal commands.

`tk transcription` starts Enchanted Transcription: local Whisper capture for microphone and system output with an optional OpenAI-powered Agent Insights pane. F9 provides transcription, agent, reference-context, transparency, and API-safety settings. Language/model and reference-context selection are session-only, starting at English `medium.en` and no context; the other settings remain persistent. Local capture and context buffering continue when API requests are paused. See the [Enchanted Transcription guide](agents/enchanted-transcription/README.md) for controls, defaults, privacy behavior, and private `.md`, `.txt`, `.json`, or `.csv` reference documents.

`tk enhanced-typing` starts the separate enhanced typing agent in `agents\enhanced-typing`. Whisper captures from microphone or system output, the OpenAI agent refines completed phrases when intelligence is available, and the tool appends them into an on-screen draft. It uses English by default with `ggml-medium.en.bin`; pass `-Language auto` or another language code to use `ggml-medium.bin`. Press F1 to show the terminal when it is hidden, or flush the draft when the terminal is focused; Ctrl+Alt+F1 is also registered as a backup show shortcut when Windows allows it. Flush mode can copy to clipboard, type into the last target app, or discard the draft. Press F9 for settings; settings pauses listening and lets you change input source, intelligence, flush mode, transparency, and refiner model.

`tk openai-key` stores or updates an OpenAI API key encrypted with Windows DPAPI for tools that need OpenAI access. `tk openai-key -Status` shows whether a key is configured without printing it.

The reboot guard keeps Windows Update enabled, but blocks automatic Windows Update restarts while a user is logged in. Run `tk reboot` for the simple status-and-toggle screen. Changing the guard requires administrator approval.

`tk caatuu` opens a startup menu for the Caatuu workspace at `C:\Work\caatuu`. It can start the local server alone, start it with the shared Cloudflare tunnel, show container and endpoint status, verify the local and active public endpoints, or stop Caatuu while preserving the tunnel used by Minerals. Stopping the shared tunnel is a separate, explicitly warned action. Startup is idempotent, Docker Desktop is started automatically when needed, and each start waits for both container health and the corresponding HTTP endpoint before reporting success. Starting Caatuu also exposes its explicitly versioned Android sideload channel so installed debug-signed builds can check and download updates.

`tk storage` opens a control menu for `C:\Work\storage-and-sharing-services`. It directly manages one `debian:latest` container and runs the repository's dependency-only `setup.sh` when that environment starts; no Dockerfile or Compose file is used. Normal start reuses a stopped container, while explicit rebuild replaces only that named container and preserves the host sharing folders. Status and stop never launch Docker Desktop or delete anything. The service has no automatic restart policy.

## PDF compression

Open **Files & media / Compress PDF** in `tk`, or run `tk compress-pdf`. Choose a PDF in the Windows picker to open the settings editor. It shows the file size, page count, compression controls, save mode, and destination together. Settings apply to the current session.

```cmd
tk compress-pdf
tk compress-pdf "C:\Work\documents\report.pdf" -Menu
tk compress-pdf "C:\Work\documents\report.pdf"
tk compress-pdf "C:\Work\documents\report.pdf" -Preset Small
tk compress-pdf "C:\Work\documents\report.pdf" -Quality 80 -MaxImageDimension 1600
tk compress-pdf "C:\Work\documents\report.pdf" -Grayscale -RemoveMetadata
tk compress-pdf "C:\Work\documents\report.pdf" -OverwriteOriginal
tk compress-pdf "C:\Work\documents\report.pdf" -OverwriteOriginal -NoBackup
tk compress-pdf "C:\Work\documents\report.pdf" "C:\Work\documents\smaller.pdf" -Json
tk compress-pdf -Help
```

`pdf-compress` and `shrink-pdf` are aliases. An explicit PDF runs immediately with the supplied options; add `-Menu` to edit them interactively first. Relative and Unicode paths are supported. `-Json` requires a PDF and cannot be combined with `-Menu`.

### Compression settings

| Preset | Image quality | Maximum image edge |
| --- | --- | --- |
| Balanced (default) | JPEG 88 | Original resolution |
| HighQuality | JPEG 95 | Original resolution |
| Small | JPEG 65 | 1600 pixels |
| Lossless | Image pixels unchanged | Original resolution |
| Custom | Adjustable from 20 to 95 | Original, or 128 to 10000 pixels |

Adjust image quality or resolution to switch to Custom. Resizing preserves proportions, never enlarges images, and resizes transparency masks with their images. `-MaxImageDimension 0` keeps original resolution. `-Grayscale` affects supported raster images only: vector text and graphics keep their colors. `-RemoveMetadata` removes document properties and document-level XMP; it does not remove visible text or attachments. Lossless can remove metadata, but cannot be combined with image quality, resizing, or grayscale changes.

All presets compress page streams and remove duplicate/unreferenced PDF objects. Pages, selectable text, bookmarks, links, forms, and attachments remain. Tiny icons, inline images, custom color spaces, color-key masks, and unsupported image encodings are kept unchanged. Scanned text is part of raster images and can lose detail with lower quality or resolution. Use Lossless when every image pixel matters.

### Saving

**New copy is the default:** `report.pdf` becomes `report - compressed.pdf` beside the source. Existing filenames add ` (2)`, ` (3)`, and so on. **D / Save as** chooses a custom new filename or folder. Existing files cannot be selected through Save as.

Switch **Save mode** to **Overwrite original** to save at the input path. The screen clearly shows `REPLACE`, the destination filename, and whether a backup will be kept. Press **C**, or Enter on **COMPRESS & SAVE**, to compress and save with the displayed choices. No separate confirmation dialog is needed. Overwrite keeps a byte-for-byte backup as `report - original.pdf` by default, with numbered suffixes for collisions. Toggle **Original backup** off, or pass `-NoBackup` with `-OverwriteOriginal`, to replace without that backup.

The engine writes a temporary PDF in the destination directory, reopens it to verify page content, navigation, and form values, and publishes it only if it is smaller. Overwrite also checks that the original file has not changed during compression before replacing it. A failed replacement preserves the original; a completed backup is retained and its path is included in the error. If there is no size reduction, no copy, backup, or replacement is made. Digitally signed and encrypted PDFs require unsigned/unprotected copies.

### Terminal controls

| Key | Action |
| --- | --- |
| Up / Down, Home / End | Select a setting or the Compress & Save action |
| Left / Right, Space | Change a preset, value, or toggle |
| Enter | Edit quality/resolution numerically, toggle a setting, or start the selected save action |
| C | Compress and save with the displayed settings and destination |
| F / P | Choose another PDF / paste a path |
| D | Choose a custom new output filename and folder |
| R | Reset to Balanced and saving a new copy |
| Q / Esc | Close without starting compression |

The settings list scrolls in smaller terminals. Selecting another PDF keeps compression choices but resets the save mode to New copy. After compression, the result screen shows sizes, reduction, image changes, output path, and any backup; use **O** to open the saved PDF, **T** to tweak settings, **F** for another file, or Enter/Q/Esc to close. A failed compression returns to the editor with its error. Sizes use binary KB/MB units.

Compression runs locally with Python 3.10+, `pypdf` 6.x, and Pillow. Python discovery and `TUKEVEJTSO_PDF_PYTHON` work the same way as the PDF joiner. Nothing is uploaded, dependencies are not installed automatically, and Docker is not used. If dependencies are missing:

```cmd
py -m pip install "pypdf>=6,<7" Pillow
```

Run the automated checks from the repository root:

```powershell
py -m unittest discover -s windows/tools/tests -p test_pdf_compress.py
powershell.exe -NoProfile -ExecutionPolicy Bypass -File windows/tools/tests/test_compress_pdf.ps1
```

## PDF joiner

Open **PDF / Join files** in the `tk` menu, or run:

```cmd
tk join-pdfs
tk join-pdfs "C:\Work\documents" -Recursive
tk join-pdfs -Help
```

`pdf-join` and `merge-pdfs` are aliases. An explicit folder argument selects that folder and skips the Windows picker. Subfolder scanning starts enabled for new settings and is enabled once when upgrading older settings. Press **R** to switch to the selected folder only; that preference is remembered. `-Recursive` explicitly enables subfolder scanning; when omitted, the saved recursion setting is used.

The joined PDF is always saved directly in the folder selected for searching, including when its inputs come from subfolders. Its filename uses the first PDF's full name without `.pdf`, followed by the first word of each remaining PDF in merge order, separated by ` - `. Spaces, underscores, and hyphens separate words. For example, `Application form.pdf`, `nested\Passport copy.PDF`, and `Bank_statement.pdf` produce `Application form - Passport - Bank.pdf` in the search folder. The output name updates when you select, deselect, or reorder files. Existing files and source PDFs are never overwritten: a collision adds ` (2)`, ` (3)`, and so on before `.pdf`. If the resulting full path exceeds 240 characters, the tool reports an error so you can shorten the source filenames or adjust the selection.

After a successful merge, the tool shows the saved PDF path and **Press any key to close**. A keypress exits the PDF joiner without reopening the selection list; your folder and selections remain saved for the next launch.

Without a folder argument, the Windows folder picker opens on every launch. The last folder is only its initial view: press **Select folder** to confirm it or choose another folder. No Documents or working folder is assumed. Cancelling at startup exits without scanning files or changing saved settings. In the PDF list, press **F** to reopen the Windows picker or **P** to paste or type a folder path.

The browse view shows a PDF-only folder tree with indentation and branch lines, inside a bordered area with a dark gray background. Folder headings provide context and cannot be selected; navigation moves between PDFs. The list scrolls as the highlight reaches its top or bottom edge. **↑ More above** and **↓ More below** appear in the panel borders when more rows are available in that direction. Filtering keeps the matching PDFs' ancestor folders visible. **Tab** switches to a flat list showing the exact merge order, and the review screen uses that same order. Use these controls:

| Key | Action |
| --- | --- |
| Up / Down | Move one PDF at a time, scrolling at the list edges and skipping folder headings |
| Page Up / Page Down | Same as Up / Down |
| Home / End | Move to the first / last PDF |
| F / P | Open the Windows folder picker / paste a folder path |
| R | Toggle between all subfolders and the selected folder only |
| / | Filter filenames |
| Space | Select or deselect the highlighted PDF |
| A / N | Select all visible files / clear visible selections |
| Tab | Switch between the folder tree and flat selected merge order |
| + / - | Move the highlighted selected PDF later / earlier |
| F5 | Refresh the folder contents |
| Enter | Review the selected files, then merge |
| Q / Esc | Go back or exit |

The last folder, recursion setting, selected files, merge order, and most recent result are stored in `%LOCALAPPDATA%\tukevejtso\pdf-join.json` using settings version 2. Older settings migrate once to include subfolders while preserving the chosen folder, selections, and merge order; later changes to the recursion preference are retained. Only the most recent folder is remembered. Confirming the same folder preserves its selection and order; choosing another folder clears the selection. The output name is derived from the current selection, and a destination saved by an older version is ignored. Filtering the list does not remove selected files hidden by the filter. Review the selected-order view before merging.

The merger runs locally using Python 3.10 or newer and `pypdf` 6.x. It discovers a suitable Python on `PATH`, then checks the Codex bundled runtime when available. To choose a specific executable, set `TUKEVEJTSO_PDF_PYTHON` to its full path. If no suitable runtime is available, install the dependency into your own Python:

```cmd
py -m pip install "pypdf>=6,<7"
```

The tool does not download dependencies or launch Docker. Encrypted PDFs must be saved as unprotected copies before merging. A failed merge reports the problem without publishing a partial result.

For a scan-only diagnostic that prints JSON without opening the interface, saving settings, or merging files, pass `-NoMenu`. Specify a folder explicitly or use the previously confirmed folder; if neither is available, the command reports an error:

```cmd
tk join-pdfs "C:\Work\documents" -Recursive -NoMenu
```

To check the workflow, use a small disposable folder containing two PDFs and a nested folder with another PDF. Choose it in the Windows picker, toggle recursion, select and reorder the files, merge, and inspect the output page order. Relaunch, confirm the remembered folder, and check the selection. Cancel a launch to check that settings remain unchanged. Repeat with an existing output name to check that it remains unchanged.

Automated checks from the repository root:

```powershell
py -m unittest discover -s windows/tools/tests -p test_pdf_join.py
powershell.exe -NoProfile -ExecutionPolicy Bypass -File windows/tools/tests/test_join_pdfs.ps1
```

## Layout

- `tk.cmd` is the stable command name.
- `toolkit.cmd` routes direct commands and opens the interactive menu.
- `agents\enchanted-transcription` contains the transcription agent.
- `agents\enhanced-typing` contains the enhanced typing agent.
- `agents\speech-agent-core` contains their shared Rust capture, Whisper, API, and terminal runtime.
- `models\whisper` contains the shared local Whisper model cache used by both agents.
- `tools/*.ps1` contains the real utilities.
- `tools/ui.ps1` contains shared terminal rendering helpers.
- `tools/pdf-runtime.ps1` shares Python discovery and JSON transport between the PDF tools.

## Interface Primitives

The Windows interface layer borrows the useful primitives from `iinuji` while staying native to stock Windows:

- panels for bounded sections
- styled status rows and badges
- small bars and sparklines
- bitmap art text
- PNG rendering from `resources/waajacamaya.png` into terminal half-block cells
