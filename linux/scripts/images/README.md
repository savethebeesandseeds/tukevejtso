# Image Scripts

Bash and Python utilities for image, GIF, and PDF cleanup work.

Run these from WSL, Linux, or another shell with the required command-line tools
installed. They are not wired into the Windows `tk` launcher.

## Files

- `image_tool.sh`: main image CLI
- `cutout.sh`: model-aware background removal CLI and GUI entrypoint
- `pdf_tool.sh`: main PDF CLI
- `lib/common.sh`: shared shell helpers
- `cluster_transparency.sh`, `gif_cluster_transparent.sh`,
  `describe_file.sh`, `merge_pdfs.sh`, `imgkit.sh`: compatibility wrappers
- `*_clean.py`, `*_filter.py`: Python helpers used by image workflows
- `edge_color_transparent.py`: experimental helper kept for manual comparison,
  not the normal transparency pipeline

## Dependencies

Most scripts expect these tools:

```bash
sudo apt-get update
sudo apt-get install -y imagemagick webp libwebp-dev ghostscript qpdf file ffmpeg
```

The repo-local Debian container already includes these dependencies. Open it
from Windows with `tk linux`.

The cutout engine has its own Python environment because modern background
removal depends on Pillow/NumPy and, optionally, PyTorch/Transformers:

```bash
./scripts/images/bootstrap_cutout_env.sh
./scripts/images/bootstrap_cutout_env.sh --ml
./scripts/images/bootstrap_cutout_env.sh --gui
```

Use `--ml` for BiRefNet and future model providers. Use `--gui` for the Qt GUI
workspace. The default bootstrap installs only the lightweight core. `--ml`
uses CPU PyTorch by default; use `--ml-cuda` in a container with CUDA exposed.
`--ml-cuda` installs `torch==2.11.0+cu128` and
`torchvision==0.26.0+cu128` from `https://download.pytorch.org/whl/cu128`.
Override with `TUK_CUTOUT_TORCH_CUDA_SPEC`,
`TUK_CUTOUT_TORCHVISION_CUDA_SPEC`, or `TUK_CUTOUT_TORCH_CUDA_INDEX_URL` if
the PyTorch wheel set changes. Inside the Docker runtime, the venv defaults to
`/opt/tukevejtso-venvs/cutout`, a Docker named volume, so large CUDA wheels do
not live on the Windows-mounted repo.

## Recommended Commands

The usual background-removal workflow is now `cutout`. It uses BiRefNet by
default in the Windows wrapper, writes transparent PNGs, and uses CUDA when the
container has a CUDA-enabled PyTorch environment. See `../../../CUTOUT.md` for
the operator guide.

From `linux/`, inspect an image:

```bash
./scripts/images/image_tool.sh inspect \
  ./workspaces/images/logo.png \
  ./workspaces/images/logo_report.txt
```

Quantize an image:

```bash
./scripts/images/image_tool.sh palette \
  ./workspaces/images/egg.png \
  ./workspaces/images/egg_palette2.png \
  --colors 2
```

Make one cluster transparent:

```bash
./scripts/images/image_tool.sh cluster-transparent \
  ./workspaces/images/parrot_2.png \
  --colors 2 \
  --cluster 0 \
  --color "#81888B"
```

Remove a background with the cutout engine:

```bash
./scripts/images/image_tool.sh cutout image \
  ./workspaces/images/product.jpg \
  ./workspaces/images/product_cutout.png \
  --engine auto \
  --alpha-output ./workspaces/images/product_alpha.png \
  --mask-output ./workspaces/images/product_mask.png \
  --diagnostics ./workspaces/images/product_cutout.json \
  --preview-dir ./workspaces/images/product_previews
```

Check dependencies and model notes:

```bash
./scripts/images/image_tool.sh cutout doctor
./scripts/images/image_tool.sh cutout models
```

After installing the optional ML dependencies, run BiRefNet explicitly:

```bash
./scripts/images/bootstrap_cutout_env.sh --ml-cuda --gui
./scripts/images/image_tool.sh cutout image \
  ./workspaces/images/person.jpg \
  ./workspaces/images/person_cutout.png \
  --engine birefnet \
  --device auto
```

Batch-process a test folder while saving sidecars for inspection:

```bash
./scripts/images/image_tool.sh cutout batch \
  ./workspaces/images/tests \
  ./workspaces/images/tests-output-birefnet \
  --engine birefnet \
  --device auto \
  --alpha-floor 24 \
  --alpha-ceiling 250 \
  --save-extras \
  --diagnostics ./workspaces/images/tests-output-birefnet/report.json
```

For normal use, omit `--save-extras`; the batch command writes only final
transparent PNG files. Use `--clean-output` when you want the output folder
deleted before the run:

```bash
./scripts/images/image_tool.sh cutout batch \
  ./workspaces/images/tests \
  ./workspaces/images/tests-output-final \
  --engine birefnet \
  --device cpu \
  --clean-output
```

Deprecated color-based background removal:

```bash
./scripts/images/image_tool.sh white-to-transparent \
  ./workspaces/images/logo.png \
  ./workspaces/images/logo_transparent.png \
  --fuzz 10%
```

`white-to-transparent`, `mask-alpha`, `cluster-transparent`,
`cluster-white-transparent`, `gif-cluster-transparent`, and
`edge-color-transparent` are retained for compatibility and manual comparisons,
but they are deprecated for normal background removal. Prefer `cutout`.

Build a threshold mask and apply alpha:

```bash
./scripts/images/image_tool.sh mask-alpha \
  ./workspaces/images/logo.png \
  --threshold 99% \
  --dilate 2.0
```

Process a GIF frame-by-frame:

```bash
./scripts/images/image_tool.sh gif-cluster-transparent \
  ./workspaces/videos/input.gif \
  ./workspaces/videos/output.cleaned.gif \
  --colors 5 \
  --cluster 0
```

Shrink a PDF:

```bash
./scripts/images/pdf_tool.sh shrink \
  ./workspaces/pdf/input.pdf \
  ./workspaces/pdf/input_small.pdf \
  --preset /ebook
```

Merge PDFs:

```bash
./scripts/images/pdf_tool.sh merge \
  ./workspaces/pdf/merged.pdf \
  ./workspaces/pdf/parts/*.pdf
```

## Legacy Wrappers

These still work if muscle memory matters:

```bash
./scripts/images/cluster_transparency.sh \
  --input ./workspaces/images/parrot_2.png \
  --n 2 \
  --idx 0 \
  --color "#81888B"
./scripts/images/imgkit.sh help
./scripts/images/imgkit.sh palette2 ./workspaces/images/egg.png
./scripts/images/describe_file.sh \
  ./workspaces/images/logo.png \
  ./workspaces/images/_image_report.txt
./scripts/images/gif_cluster_transparent.sh \
  ./workspaces/videos/input.gif \
  ./workspaces/videos/output.cleaned.gif
./scripts/images/merge_pdfs.sh \
  ./workspaces/pdf/merged.pdf \
  ./workspaces/pdf/parts/*.pdf
```

## Experimental Helpers

`edge-color-transparent` is retained only as an opt-in experiment for comparing
edge-connected color removal. It did not produce reliable results for the galaxy
assets, so do not treat it as a recommended pipeline.

```bash
./scripts/images/image_tool.sh edge-color-transparent \
  ./workspaces/images/input.png \
  ./workspaces/images/input_edge_transparent.png \
  --color black \
  --tolerance 1 \
  --min-area 3000
```

## Notes

- Keep reusable behavior in `image_tool.sh` or `pdf_tool.sh` before adding new
  one-off scripts.
- Treat `cutout_engine/` as the durable home for learned segmentation, alpha
  matting, post-processing, batch processing, GUI, and future local API work.
- Keep generated images, frame dumps, temporary PDFs, and video experiments in
  `../../workspaces/`.
- Promote durable examples intentionally by adding a narrow exception to
  `../../.gitignore`.
