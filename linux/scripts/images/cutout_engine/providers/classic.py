from __future__ import annotations

from collections import deque
from pathlib import Path

from ..errors import MissingDependencyError
from ..image_io import open_rgba
from ..types import CutoutOptions, CutoutResult


PRESETS = {
    "fast": {"tolerance": 30.0, "edge_softness": 0.8},
    "balanced": {"tolerance": 42.0, "edge_softness": 1.4},
    "pro": {"tolerance": 54.0, "edge_softness": 2.0},
}


def _deps():
    try:
        from PIL import Image, ImageFilter
        import numpy as np
    except ImportError as exc:
        raise MissingDependencyError(
            "Classic cutout needs Pillow and NumPy. Run "
            "`./scripts/images/bootstrap_cutout_env.sh` from linux/ first."
        ) from exc
    return Image, ImageFilter, np


def estimate_border_palette(
    rgb,
    alpha,
    *,
    max_colors: int,
) -> list[tuple[int, int, int]]:
    Image, _, np = _deps()
    height, width, _ = rgb.shape
    border = np.concatenate(
        [
            rgb[0, :, :],
            rgb[height - 1, :, :],
            rgb[:, 0, :],
            rgb[:, width - 1, :],
        ],
        axis=0,
    )
    border_alpha = np.concatenate(
        [
            alpha[0, :],
            alpha[height - 1, :],
            alpha[:, 0],
            alpha[:, width - 1],
        ],
        axis=0,
    )
    border = border[border_alpha > 0]
    if border.size == 0:
        return [(255, 255, 255)]

    if len(border) > 50000:
        step = max(1, len(border) // 50000)
        border = border[::step]

    sample = Image.fromarray(border.astype(np.uint8).reshape(1, len(border), 3), "RGB")
    quantized = sample.quantize(colors=max(1, max_colors), method=Image.Quantize.MEDIANCUT)
    palette = quantized.getpalette() or []
    counts = quantized.getcolors(maxcolors=max(1, max_colors) * 4) or []
    colors: list[tuple[int, int, int]] = []
    for _, index in sorted(counts, reverse=True):
        offset = index * 3
        colors.append((palette[offset], palette[offset + 1], palette[offset + 2]))
    return colors or [tuple(np.median(border, axis=0).astype(np.uint8).tolist())]


def distance_to_palette(rgb, palette: list[tuple[int, int, int]]):
    _, _, np = _deps()
    distances = []
    rgb_f = rgb.astype(np.float32)
    for color in palette:
        target = np.array(color, dtype=np.float32).reshape(1, 1, 3)
        distances.append(np.linalg.norm(rgb_f - target, axis=2))
    return np.minimum.reduce(distances)


def flood_connected_background(candidate):
    _, _, np = _deps()
    height, width = candidate.shape
    visited = np.zeros(candidate.shape, dtype=bool)
    queue: deque[tuple[int, int]] = deque()

    def add(y: int, x: int) -> None:
        if candidate[y, x] and not visited[y, x]:
            visited[y, x] = True
            queue.append((y, x))

    for x in range(width):
        add(0, x)
        add(height - 1, x)
    for y in range(height):
        add(y, 0)
        add(y, width - 1)

    while queue:
        y, x = queue.popleft()
        if y > 0:
            add(y - 1, x)
        if y < height - 1:
            add(y + 1, x)
        if x > 0:
            add(y, x - 1)
        if x < width - 1:
            add(y, x + 1)

    return visited


def decontaminate_edges(
    rgb,
    alpha,
    background: tuple[int, int, int],
):
    _, _, np = _deps()
    alpha_f = np.clip(alpha.astype(np.float32) / 255.0, 0.0, 1.0)
    edge = (alpha_f > 0.02) & (alpha_f < 0.98)
    if not np.any(edge):
        return rgb

    bg = np.array(background, dtype=np.float32).reshape(1, 1, 3)
    out = rgb.astype(np.float32)
    safe_alpha = np.maximum(alpha_f, 0.08)
    estimated = (out - bg * (1.0 - safe_alpha[..., None])) / safe_alpha[..., None]
    out[edge] = np.clip(estimated[edge], 0, 255)
    return out.astype(np.uint8)


def run(input_path: Path, options: CutoutOptions) -> CutoutResult:
    Image, ImageFilter, np = _deps()
    image = open_rgba(input_path)
    rgba = np.array(image, dtype=np.uint8)
    rgb = rgba[:, :, :3]
    existing_alpha = rgba[:, :, 3]

    preset = PRESETS.get(options.preset, PRESETS["balanced"])
    tolerance = options.tolerance if options.tolerance is not None else preset["tolerance"]
    edge_softness = (
        options.edge_softness
        if options.edge_softness is not None
        else preset["edge_softness"]
    )

    palette = estimate_border_palette(
        rgb,
        existing_alpha,
        max_colors=options.bg_palette_size,
    )
    distance = distance_to_palette(rgb, palette)
    candidate = (distance <= tolerance) | (existing_alpha == 0)
    background = flood_connected_background(candidate)

    hard_alpha = np.where(background, 0, existing_alpha).astype(np.uint8)
    hard_mask = Image.fromarray(np.where(background, 0, 255).astype(np.uint8), "L")

    alpha_image = Image.fromarray(hard_alpha, "L")
    if edge_softness > 0:
        alpha_image = alpha_image.filter(ImageFilter.GaussianBlur(radius=edge_softness))
    alpha = np.array(alpha_image, dtype=np.uint8)

    clean_rgb = rgb
    if options.decontaminate and palette:
        clean_rgb = decontaminate_edges(rgb, alpha, palette[0])

    out = np.dstack([clean_rgb, alpha]).astype(np.uint8)
    result = Image.fromarray(out, "RGBA")

    removed_pixels = int(np.count_nonzero(background))
    total_pixels = int(background.size)
    return CutoutResult(
        rgba=result,
        alpha=alpha_image,
        hard_mask=hard_mask,
        diagnostics={
            "engine": "classic",
            "preset": options.preset,
            "tolerance": tolerance,
            "edge_softness": edge_softness,
            "background_palette": [f"#{r:02X}{g:02X}{b:02X}" for r, g, b in palette],
            "removed_pixels": removed_pixels,
            "total_pixels": total_pixels,
            "removed_ratio": removed_pixels / total_pixels if total_pixels else 0.0,
            "warning": "Classic mode is a fallback for simple backgrounds, not a learned matting model.",
        },
    )
