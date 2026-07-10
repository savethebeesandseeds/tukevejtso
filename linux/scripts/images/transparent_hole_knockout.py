#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image, ImageDraw, ImageFilter


Shape = dict[str, Any]


@dataclass(slots=True)
class KnockoutItem:
    file: str
    erase: list[Shape]
    protect: list[Shape]
    force_erase: list[Shape]
    match: dict[str, Any] | None
    feather: float
    protect_feather: float
    supersample: int


def die(message: str) -> None:
    print(f"transparent_hole_knockout.py: error: {message}", file=sys.stderr)
    raise SystemExit(2)


def read_config(path: Path) -> list[dict[str, Any]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        die(f"invalid JSON config {path}: {exc}")

    if isinstance(data, list):
        items = data
    elif isinstance(data, dict):
        items = data.get("images", data.get("items"))
    else:
        items = None

    if not isinstance(items, list) or not items:
        die("config must contain a non-empty 'images' list")
    return items


def as_box(shape: Shape) -> tuple[float, float, float, float]:
    if "box" in shape:
        box = shape["box"]
    else:
        box = [shape.get("left"), shape.get("top"), shape.get("right"), shape.get("bottom")]
    if not isinstance(box, list) or len(box) != 4:
        die(f"shape requires a four-value box: {shape}")
    return tuple(float(value) for value in box)  # type: ignore[return-value]


def scaled_box(box: tuple[float, float, float, float], scale: int) -> tuple[int, int, int, int]:
    return tuple(int(round(value * scale)) for value in box)  # type: ignore[return-value]


def scaled_points(points: Any, scale: int) -> list[tuple[int, int]]:
    if not isinstance(points, list) or len(points) < 3:
        die(f"polygon requires at least three points: {points}")
    return [(int(round(float(x) * scale)), int(round(float(y) * scale))) for x, y in points]


def draw_shape(draw: ImageDraw.ImageDraw, shape: Shape, *, fill: int, scale: int) -> None:
    shape_type = str(shape.get("type", "polygon")).lower()

    if shape_type == "rect":
        draw.rectangle(scaled_box(as_box(shape), scale), fill=fill)
    elif shape_type == "ellipse":
        draw.ellipse(scaled_box(as_box(shape), scale), fill=fill)
    elif shape_type == "polygon":
        draw.polygon(scaled_points(shape.get("points"), scale), fill=fill)
    elif shape_type == "arch":
        left = float(shape["left"])
        top = float(shape["top"])
        right = float(shape["right"])
        spring = float(shape["spring"])
        bottom = float(shape["bottom"])
        arc_box = scaled_box((left, top, right, (2 * spring) - top), scale)
        draw.pieslice(arc_box, 180, 360, fill=fill)
        draw.rectangle(scaled_box((left, spring, right, bottom), scale), fill=fill)
    else:
        die(f"unsupported shape type '{shape_type}'")


def draw_mask(
    size: tuple[int, int],
    shapes: list[Shape],
    *,
    supersample: int,
    feather: float,
) -> Image.Image:
    width, height = size
    scaled_size = (width * supersample, height * supersample)
    mask = Image.new("L", scaled_size, 0)
    draw = ImageDraw.Draw(mask)
    for shape in shapes:
        draw_shape(draw, shape, fill=255, scale=supersample)

    if feather > 0:
        mask = mask.filter(ImageFilter.GaussianBlur(feather * supersample))
        return mask.resize(size, Image.Resampling.LANCZOS)
    return mask.resize(size, Image.Resampling.NEAREST)


def combine_masks(erase: Image.Image, protect: Image.Image) -> Image.Image:
    erase_arr = np.array(erase, dtype=np.int16)
    protect_arr = np.array(protect, dtype=np.int16)
    return Image.fromarray(np.clip(erase_arr - protect_arr, 0, 255).astype(np.uint8), "L")


def intersect_masks(left: Image.Image, right: Image.Image) -> Image.Image:
    left_arr = np.array(left, dtype=np.uint8)
    right_arr = np.array(right, dtype=np.uint8)
    return Image.fromarray(np.minimum(left_arr, right_arr), "L")


def add_masks(left: Image.Image, right: Image.Image) -> Image.Image:
    left_arr = np.array(left, dtype=np.uint8)
    right_arr = np.array(right, dtype=np.uint8)
    return Image.fromarray(np.maximum(left_arr, right_arr), "L")


def build_match_mask(image: Image.Image, match: dict[str, Any]) -> Image.Image:
    match_type = str(match.get("type", "light_checker")).lower()
    if match_type not in {"light_checker", "low_saturation_light"}:
        die(f"unsupported match type '{match_type}'")

    rgba = np.array(image.convert("RGBA"), dtype=np.uint8)
    rgb = rgba[..., 0:3].astype(np.int16)
    alpha = rgba[..., 3]
    saturation = rgb.max(axis=2) - rgb.min(axis=2)
    mean = rgb.mean(axis=2)

    saturation_max = float(match.get("saturation_max", 8))
    mean_min = float(match.get("mean_min", 185))
    mean_max = float(match.get("mean_max", 255))
    alpha_min = int(match.get("alpha_min", 220))

    matched = (
        (alpha >= alpha_min)
        & (saturation <= saturation_max)
        & (mean >= mean_min)
        & (mean <= mean_max)
    )
    return Image.fromarray((matched.astype(np.uint8) * 255), "L")


def apply_knockout(image: Image.Image, mask: Image.Image) -> Image.Image:
    rgba = np.array(image.convert("RGBA"), dtype=np.uint8)
    alpha = rgba[..., 3].astype(np.float32)
    mask_arr = np.array(mask, dtype=np.float32) / 255.0
    new_alpha = (alpha * (1.0 - mask_arr)).clip(0, 255).astype(np.uint8)
    rgba[..., 3] = new_alpha
    rgba[new_alpha == 0, 0:3] = 0
    return Image.fromarray(rgba, "RGBA")


def write_checker_preview(image: Image.Image, output: Path, *, cell: int = 24) -> None:
    width, height = image.size
    checker = Image.new("RGB", (width, height), "white")
    draw = ImageDraw.Draw(checker)
    for y in range(0, height, cell):
        for x in range(0, width, cell):
            if ((x // cell) + (y // cell)) % 2 == 0:
                draw.rectangle((x, y, x + cell - 1, y + cell - 1), fill=(200, 200, 200))
    preview = checker.convert("RGBA")
    preview.alpha_composite(image.convert("RGBA"))
    output.parent.mkdir(parents=True, exist_ok=True)
    preview.convert("RGB").save(output, quality=92)


def parse_item(raw: dict[str, Any], args: argparse.Namespace) -> KnockoutItem:
    file_name = raw.get("file")
    if not isinstance(file_name, str) or not file_name:
        die(f"item requires a file name: {raw}")

    erase = raw.get("erase")
    if not isinstance(erase, list) or not erase:
        die(f"{file_name}: item requires a non-empty erase list")

    protect = raw.get("protect", [])
    if not isinstance(protect, list):
        die(f"{file_name}: protect must be a list")
    force_erase = raw.get("force_erase", [])
    if not isinstance(force_erase, list):
        die(f"{file_name}: force_erase must be a list")
    match = raw.get("match")
    if match is not None and not isinstance(match, dict):
        die(f"{file_name}: match must be an object")

    return KnockoutItem(
        file=file_name,
        erase=erase,
        protect=protect,
        force_erase=force_erase,
        match=match,
        feather=float(raw.get("feather", args.default_feather)),
        protect_feather=float(raw.get("protect_feather", args.default_protect_feather)),
        supersample=int(raw.get("supersample", args.supersample)),
    )


def output_for(input_path: Path, args: argparse.Namespace) -> Path:
    if args.in_place:
        return input_path
    if args.output_dir is None:
        die("use --output-dir or --in-place")
    return args.output_dir / input_path.name


def backup_original(input_path: Path, args: argparse.Namespace) -> None:
    if not args.in_place or args.backup_dir is None:
        return
    backup = args.backup_dir / input_path.name
    backup.parent.mkdir(parents=True, exist_ok=True)
    if not backup.exists():
        shutil.copy2(input_path, backup)


def process_item(item: KnockoutItem, args: argparse.Namespace) -> dict[str, Any]:
    input_path = args.input_dir / item.file
    if not input_path.is_file():
        die(f"input not found: {input_path}")

    image = Image.open(input_path).convert("RGBA")
    erase = draw_mask(image.size, item.erase, supersample=item.supersample, feather=item.feather)
    if item.match is not None:
        erase = intersect_masks(erase, build_match_mask(image, item.match))

    if item.protect:
        protect = draw_mask(
            image.size,
            item.protect,
            supersample=item.supersample,
            feather=item.protect_feather,
        )
        mask = combine_masks(erase, protect)
    else:
        mask = erase

    if item.force_erase:
        forced = draw_mask(
            image.size,
            item.force_erase,
            supersample=item.supersample,
            feather=item.feather,
        )
        mask = add_masks(mask, forced)

    output_path = output_for(input_path, args)
    backup_original(input_path, args)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    result = apply_knockout(image, mask)
    result.save(output_path)

    if args.preview_dir is not None:
        preview_path = args.preview_dir / f"{input_path.stem}_hole_preview.jpg"
        write_checker_preview(result, preview_path)
    else:
        preview_path = None

    if args.mask_dir is not None:
        mask_path = args.mask_dir / f"{input_path.stem}_hole_mask.png"
        mask_path.parent.mkdir(parents=True, exist_ok=True)
        mask.save(mask_path)
    else:
        mask_path = None

    before_alpha = np.array(image.getchannel("A"), dtype=np.uint8)
    after_alpha = np.array(result.getchannel("A"), dtype=np.uint8)
    changed = int(np.count_nonzero(before_alpha != after_alpha))
    made_transparent = int(np.count_nonzero((before_alpha > 0) & (after_alpha == 0)))

    return {
        "file": item.file,
        "output": str(output_path),
        "preview": str(preview_path) if preview_path else None,
        "mask": str(mask_path) if mask_path else None,
        "changed_alpha_pixels": changed,
        "made_transparent_pixels": made_transparent,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Apply config-driven transparent knockout masks to enclosed sprite holes.",
    )
    parser.add_argument("config", type=Path, help="JSON config with an images list")
    parser.add_argument("--input-dir", type=Path, required=True, help="Directory containing input PNGs")
    output = parser.add_mutually_exclusive_group(required=True)
    output.add_argument("--output-dir", type=Path, help="Directory for cleaned PNGs")
    output.add_argument("--in-place", action="store_true", help="Overwrite input PNGs")
    parser.add_argument("--preview-dir", type=Path, help="Write checkerboard previews here")
    parser.add_argument("--mask-dir", type=Path, help="Write grayscale knockout masks here")
    parser.add_argument("--backup-dir", type=Path, help="When using --in-place, copy originals here first")
    parser.add_argument("--manifest", type=Path, help="Write a JSON report")
    parser.add_argument("--default-feather", type=float, default=0.35)
    parser.add_argument("--default-protect-feather", type=float, default=0.9)
    parser.add_argument("--supersample", type=int, default=4)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    args.config = args.config.resolve()
    args.input_dir = args.input_dir.resolve()
    if args.output_dir is not None:
        args.output_dir = args.output_dir.resolve()
    if args.preview_dir is not None:
        args.preview_dir = args.preview_dir.resolve()
    if args.mask_dir is not None:
        args.mask_dir = args.mask_dir.resolve()
    if args.backup_dir is not None:
        args.backup_dir = args.backup_dir.resolve()

    raw_items = read_config(args.config)
    items = [parse_item(raw, args) for raw in raw_items]
    results = [process_item(item, args) for item in items]

    report = {
        "config": str(args.config),
        "input_dir": str(args.input_dir),
        "output_dir": str(args.output_dir) if args.output_dir else None,
        "in_place": bool(args.in_place),
        "count": len(results),
        "results": results,
    }

    if args.manifest is not None:
        args.manifest.parent.mkdir(parents=True, exist_ok=True)
        args.manifest.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
