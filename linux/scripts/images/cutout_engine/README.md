# cutout_engine

Model-aware background removal package used by:

```bash
./scripts/images/image_tool.sh cutout ...
./scripts/images/cutout.sh ...
```

## Modules

- `cli.py`: command parser for `image`, `batch`, `doctor`, `models`, and `gui`.
- `pipeline.py`: chooses the requested engine and handles fallback behavior.
- `providers/birefnet.py`: BiRefNet/Hugging Face segmentation provider.
- `providers/classic.py`: local color/edge fallback provider.
- `postprocess.py`: alpha cleanup, decontamination, and previews.
- `image_io.py`: image loading and default output naming.
- `gui.py`: optional PySide6 desktop UI.
- `dependencies.py`: `doctor` checks.
- `types.py`: shared option/result data classes.

New learned segmentation, alpha matting, local model providers, and GUI work
should live here instead of adding more one-off background-removal scripts.
