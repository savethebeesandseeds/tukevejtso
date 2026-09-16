from __future__ import annotations

from collections import deque
from pathlib import Path

from ..errors import MissingDependencyError
from ..image_io import open_rgba
from ..types import CutoutOptions, CutoutResult


def _deps():
    try:
        from PIL import Image
        import numpy as np
    except ImportError as exc:
        raise MissingDependencyError(
            "Artwork cutout needs Pillow and NumPy. Run "
            "`./scripts/images/bootstrap_cutout_env.sh` from linux/ first."
        ) from exc
    return Image, np


def _srgb_to_linear(values, np):
    values = np.clip(values, 0.0, 1.0)
    return np.where(values <= 0.04045, values / 12.92, ((values + 0.055) / 1.055) ** 2.4)


def _srgb_to_lab(values, np):
    linear = _srgb_to_linear(values, np)
    xyz = linear @ np.array(
        [
            [0.4124564, 0.3575761, 0.1804375],
            [0.2126729, 0.7151522, 0.0721750],
            [0.0193339, 0.1191920, 0.9503041],
        ],
        dtype=np.float32,
    ).T
    xyz /= np.array([0.95047, 1.0, 1.08883], dtype=np.float32)
    delta = 6.0 / 29.0
    transformed = np.where(
        xyz > delta**3,
        np.cbrt(xyz),
        xyz / (3.0 * delta**2) + 4.0 / 29.0,
    )
    return np.stack(
        [
            116.0 * transformed[..., 1] - 16.0,
            500.0 * (transformed[..., 0] - transformed[..., 1]),
            200.0 * (transformed[..., 1] - transformed[..., 2]),
        ],
        axis=-1,
    )


def _coordinates(height: int, width: int, np):
    y = np.linspace(-1.0, 1.0, height, dtype=np.float32)
    x = np.linspace(-1.0, 1.0, width, dtype=np.float32)
    return np.meshgrid(x, y)


def _quadratic_features(x, y, np):
    return np.stack([np.ones_like(x), x, y, x * x, x * y, y * y], axis=-1)


def estimate_background(rgb, *, model: str):
    _, np = _deps()
    height, width, _ = rgb.shape
    edge = max(8, int(round(min(height, width) * 0.06)))
    border = np.zeros((height, width), dtype=bool)
    border[:edge, :] = True
    border[-edge:, :] = True
    border[:, :edge] = True
    border[:, -edge:] = True

    if model == "flat":
        color = np.median(rgb[border], axis=0)
        background = np.broadcast_to(color, rgb.shape).astype(np.float32).copy()
        residual = np.linalg.norm(rgb[border] - color, axis=1)
        return background, {
            "background_model": model,
            "background_rgb": [round(float(value), 3) for value in color],
            "background_border_error_p95": round(float(np.percentile(residual, 95)), 4),
        }
    if model != "quadratic":
        raise ValueError(f"Unknown artwork background model: {model}")

    x, y = _coordinates(height, width, np)
    features = _quadratic_features(x, y, np)
    sample_x = features[border]
    sample_y = rgb[border]
    keep = np.ones(len(sample_x), dtype=bool)
    coefficients = None
    for _ in range(5):
        coefficients, *_ = np.linalg.lstsq(sample_x[keep], sample_y[keep], rcond=None)
        residual = np.linalg.norm(sample_y - sample_x @ coefficients, axis=1)
        median = np.median(residual[keep])
        mad = np.median(np.abs(residual[keep] - median))
        cutoff = median + max(1.0, 3.5 * 1.4826 * mad)
        updated = residual <= cutoff
        if np.array_equal(updated, keep):
            break
        keep = updated
    if coefficients is None:
        raise RuntimeError("Could not fit the artwork background model.")
    background = np.clip(features @ coefficients, 0.0, 255.0).astype(np.float32)
    residual = np.linalg.norm(sample_y - sample_x @ coefficients, axis=1)
    center = background[height // 2, width // 2]
    return background, {
        "background_model": model,
        "background_rgb_center": [round(float(value), 3) for value in center],
        "background_border_error_p95": round(float(np.percentile(residual[keep], 95)), 4),
        "background_fit_samples": int(np.count_nonzero(keep)),
    }


def connected_hysteresis(weak, strong):
    _, np = _deps()
    height, width = weak.shape
    kept = strong.copy()
    queue = deque(zip(*np.nonzero(strong), strict=False))
    while queue:
        y, x = queue.popleft()
        for dy in (-1, 0, 1):
            yy = y + dy
            if yy < 0 or yy >= height:
                continue
            for dx in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                xx = x + dx
                if 0 <= xx < width and weak[yy, xx] and not kept[yy, xx]:
                    kept[yy, xx] = True
                    queue.append((yy, xx))
    return kept


def filter_components(alpha, support, *, edge_guard: int):
    _, np = _deps()
    height, width = support.shape
    visited = np.zeros(support.shape, dtype=bool)
    kept = np.zeros(support.shape, dtype=bool)
    component_count = 0
    kept_count = 0
    for start_y, start_x in zip(*np.nonzero(support), strict=False):
        if visited[start_y, start_x]:
            continue
        component_count += 1
        queue = [(int(start_y), int(start_x))]
        visited[start_y, start_x] = True
        points: list[tuple[int, int]] = []
        while queue:
            y, x = queue.pop()
            points.append((y, x))
            for dy in (-1, 0, 1):
                yy = y + dy
                if yy < 0 or yy >= height:
                    continue
                for dx in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    xx = x + dx
                    if 0 <= xx < width and support[yy, xx] and not visited[yy, xx]:
                        visited[yy, xx] = True
                        queue.append((yy, xx))

        ys = np.fromiter((point[0] for point in points), dtype=np.int32)
        xs = np.fromiter((point[1] for point in points), dtype=np.int32)
        values = alpha[ys, xs]
        area = len(points)
        span = max(int(xs.max() - xs.min() + 1), int(ys.max() - ys.min() + 1))
        peak = float(values.max())
        mean = float(values.mean())
        keep = (
            peak >= 0.50
            or (peak >= 0.25 and area >= 4 and span >= 4)
            or (area >= 64 and span >= 20 and mean >= 0.14)
        )
        if keep:
            kept_count += 1
            kept[ys, xs] = True

    if edge_guard > 0:
        guard = min(edge_guard, height // 2, width // 2)
        kept[:guard, :] = False
        kept[-guard:, :] = False
        kept[:, :guard] = False
        kept[:, -guard:] = False
    return kept, component_count, kept_count


def run(input_path: Path, options: CutoutOptions) -> CutoutResult:
    Image, np = _deps()
    image = open_rgba(input_path)
    rgba = np.asarray(image, dtype=np.uint8)
    rgb = rgba[:, :, :3].astype(np.float32)
    existing_alpha = rgba[:, :, 3].astype(np.float32) / 255.0
    background, background_diagnostics = estimate_background(
        rgb,
        model=options.background_model,
    )

    observed_srgb = rgb / 255.0
    background_srgb = background / 255.0
    observed_linear = _srgb_to_linear(observed_srgb, np)
    background_linear = _srgb_to_linear(background_srgb, np)
    epsilon = 1e-6
    darker = np.maximum(
        (background_linear - observed_linear) / np.maximum(background_linear, epsilon),
        0.0,
    )
    lighter = np.maximum(
        (observed_linear - background_linear) / np.maximum(1.0 - background_linear, epsilon),
        0.0,
    )
    darker_srgb = np.maximum(
        (background_srgb - observed_srgb) / np.maximum(background_srgb, epsilon),
        0.0,
    )
    lighter_srgb = np.maximum(
        (observed_srgb - background_srgb) / np.maximum(1.0 - background_srgb, epsilon),
        0.0,
    )
    physical_alpha = np.clip(
        np.maximum.reduce(
            [
                np.maximum(darker, lighter).max(axis=2),
                np.maximum(darker_srgb, lighter_srgb).max(axis=2),
            ]
        ),
        0.0,
        1.0,
    )

    observed_lab = _srgb_to_lab(observed_srgb, np)
    background_lab = _srgb_to_lab(background_srgb, np)
    delta_e = np.linalg.norm(observed_lab - background_lab, axis=2)
    low = min(options.matte_low, options.matte_high)
    high = max(options.matte_low, options.matte_high)
    support = connected_hysteresis(delta_e >= low, delta_e >= high)
    alpha = np.where(support, physical_alpha * existing_alpha, 0.0)

    component_count = None
    kept_component_count = None
    if options.component_filter:
        support, component_count, kept_component_count = filter_components(
            alpha,
            support,
            edge_guard=options.edge_guard,
        )
    elif options.edge_guard > 0:
        guard = min(options.edge_guard, image.height // 2, image.width // 2)
        support[:guard, :] = False
        support[-guard:, :] = False
        support[:, :guard] = False
        support[:, -guard:] = False
    alpha = np.where(support, alpha, 0.0)

    if options.decontaminate:
        safe_alpha = np.maximum(alpha, 1.0 / 255.0)
        foreground_srgb = (
            observed_srgb - (1.0 - safe_alpha[..., None]) * background_srgb
        ) / safe_alpha[..., None]
        foreground_srgb = np.clip(foreground_srgb, 0.0, 1.0)
        foreground = np.rint(foreground_srgb * 255.0).astype(np.uint8)
    else:
        foreground = rgb.astype(np.uint8)

    alpha_u8 = np.rint(alpha * 255.0).astype(np.uint8)
    foreground[alpha_u8 == 0] = 0
    result = Image.fromarray(np.dstack([foreground, alpha_u8]), "RGBA")
    alpha_image = Image.fromarray(alpha_u8, "L")
    hard_mask = alpha_image.point(lambda pixel: 255 if pixel >= 128 else 0, mode="L")

    diagnostics = {
        "engine": "artwork",
        "matte_low": low,
        "matte_high": high,
        "edge_guard": options.edge_guard,
        "component_filter": options.component_filter,
        "decontaminate": options.decontaminate,
        "nonzero_alpha_pixels": int(np.count_nonzero(alpha_u8)),
        "total_pixels": int(alpha_u8.size),
        **background_diagnostics,
    }
    if component_count is not None:
        diagnostics["components_found"] = component_count
        diagnostics["components_kept"] = kept_component_count
    return CutoutResult(
        rgba=result,
        alpha=alpha_image,
        hard_mask=hard_mask,
        diagnostics=diagnostics,
    )
