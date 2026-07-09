from __future__ import annotations

from pathlib import Path

from .errors import MissingDependencyError
from .postprocess import cleanup_alpha
from .types import CutoutOptions, CutoutResult


def run_cutout(input_path: Path, options: CutoutOptions) -> CutoutResult:
    engine = options.engine.lower()
    if engine == "classic":
        from .providers import classic

        return cleanup_alpha(
            classic.run(input_path, options),
            floor=options.alpha_floor,
            ceiling=options.alpha_ceiling,
        )
    if engine == "birefnet":
        from .providers import birefnet

        return cleanup_alpha(
            birefnet.run(input_path, options),
            floor=options.alpha_floor,
            ceiling=options.alpha_ceiling,
        )
    if engine != "auto":
        raise ValueError(f"Unknown cutout engine: {options.engine}")

    try:
        from .providers import birefnet

        return cleanup_alpha(
            birefnet.run(input_path, options),
            floor=options.alpha_floor,
            ceiling=options.alpha_ceiling,
        )
    except MissingDependencyError as exc:
        from .providers import classic

        result = classic.run(input_path, options)
        result.diagnostics["auto_fallback"] = "birefnet"
        result.diagnostics["auto_fallback_reason"] = str(exc)
        return cleanup_alpha(
            result,
            floor=options.alpha_floor,
            ceiling=options.alpha_ceiling,
        )
