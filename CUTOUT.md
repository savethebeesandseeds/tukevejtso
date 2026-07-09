# Background Cutout

Use `tk cutout` for background removal. It writes transparent PNG files by
default and uses the GPU automatically when Docker and the cutout Python
environment can see CUDA.

## Normal Windows Use

From the repository root, or from any shell where `tk` is on `PATH`:

```powershell
.\windows\toolkit.cmd cutout "C:\path\to\input-folder"
```

or:

```powershell
tk cutout "C:\path\to\input-folder"
```

The output folder defaults to a sibling folder named:

```text
<input-folder> - transparent
```

To choose the output folder:

```powershell
tk cutout "C:\path\to\input-folder" "C:\path\to\transparent-output"
```

To delete and recreate the output folder before writing:

```powershell
tk cutout "C:\path\to\input-folder" "C:\path\to\transparent-output" -CleanOutput
```

Useful flags:

```text
-Pattern "*.png"       Input glob; defaults to PNG files.
-Recursive             Include nested input folders.
-CleanOutput           Delete the output folder before writing.
-SaveExtras            Save alpha, mask, diagnostics, and preview sidecars.
-KeepStage             Keep temporary staged files for debugging.
-Device auto|cuda|cpu  Defaults to auto.
-Engine birefnet|auto|classic
```

Good defaults are already set:

```text
engine=birefnet
device=auto
input-size=1024
alpha-floor=24
alpha-ceiling=250
```

## Linux Container Use

Open or prepare the container:

```powershell
tk linux -RecreateForGpu -NoShell
```

Run a single image from inside `linux/`:

```bash
./scripts/images/image_tool.sh cutout image \
  ./workspaces/images/tests/a\ \(1\).png \
  ./workspaces/images/a-cutout.png \
  --engine birefnet \
  --device auto \
  --diagnostics ./workspaces/images/a-cutout.json
```

Run a batch:

```bash
./scripts/images/image_tool.sh cutout batch \
  ./workspaces/images/tests \
  ./workspaces/images/tests-transparent \
  --engine birefnet \
  --device auto \
  --clean-output
```

Check the environment:

```bash
./scripts/images/image_tool.sh cutout doctor
./scripts/images/image_tool.sh cutout models
```

If diagnostics include `"device": "cuda"`, the model ran on the GPU.

## GUI

From inside the Linux container:

```bash
./scripts/images/image_tool.sh cutout gui
```

The GUI uses the same engine, defaults, and Python environment as the CLI.

## Deprecated Background Removal Commands

These commands are kept for compatibility and manual experiments, but they are
deprecated for real background removal:

```text
white-to-transparent
mask-alpha
cluster-transparent
cluster-white-transparent
gif-cluster-transparent
edge-color-transparent
cluster_transparency.sh
gif_cluster_transparent.sh
imgkit.sh white_to_transparent
imgkit.sh cluster_then_transparent
```

Use `tk cutout` or `image_tool.sh cutout` instead. The old tools are
color/threshold/cluster based; they are useful for inspection or special-case
cleanup, but they do not produce professional foreground masks reliably.

## Recovery

If the CUDA environment needs to be rebuilt, follow
[`CUTOUT_ENVIRONMENT.md`](CUTOUT_ENVIRONMENT.md).
