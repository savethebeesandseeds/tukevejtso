from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass(slots=True)
class CutoutOptions:
    engine: str = "auto"
    preset: str = "balanced"
    device: str = "auto"
    model_name: str = "ZhengPeng7/BiRefNet"
    input_size: int = 1024
    tolerance: float | None = None
    edge_softness: float | None = None
    bg_palette_size: int = 4
    alpha_floor: int = 24
    alpha_ceiling: int = 250
    decontaminate: bool = True
    save_preview_dir: Path | None = None


@dataclass(slots=True)
class CutoutResult:
    rgba: Any
    alpha: Any
    hard_mask: Any | None
    diagnostics: dict[str, Any] = field(default_factory=dict)

    def save(
        self,
        output: Path,
        *,
        alpha_output: Path | None = None,
        mask_output: Path | None = None,
    ) -> None:
        output.parent.mkdir(parents=True, exist_ok=True)
        self.rgba.save(output)
        if alpha_output is not None:
            alpha_output.parent.mkdir(parents=True, exist_ok=True)
            self.alpha.save(alpha_output)
        if mask_output is not None and self.hard_mask is not None:
            mask_output.parent.mkdir(parents=True, exist_ok=True)
            self.hard_mask.save(mask_output)
