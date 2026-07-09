from __future__ import annotations

from pathlib import Path

from .errors import MissingDependencyError


def require_pillow_numpy():
    try:
        from PIL import Image  # noqa: F401
        import numpy as np  # noqa: F401
    except ImportError as exc:
        raise MissingDependencyError(
            "The cutout engine needs Pillow and NumPy. Run "
            "`./scripts/images/bootstrap_cutout_env.sh` from linux/ first."
        ) from exc


def default_output_path(input_path: Path, suffix: str, extension: str) -> Path:
    return input_path.with_name(f"{input_path.stem}{suffix}.{extension}")


def open_rgba(path: Path):
    require_pillow_numpy()
    from PIL import Image

    return Image.open(path).convert("RGBA")
