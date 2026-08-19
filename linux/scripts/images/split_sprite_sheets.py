#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import re
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

from cutout_engine.pipeline import run_cutout
from cutout_engine.types import CutoutOptions


@dataclass(slots=True)
class Component:
    area: int
    bbox: tuple[int, int, int, int]
    centroid: tuple[float, float]
    runs: list[tuple[int, int, int]]


@dataclass(slots=True)
class Slot:
    row: int
    col: int
    anchor: tuple[float, float]
    bbox: tuple[int, int, int, int] | None = None
    area: int = 0
    components: int = 0
    runs: list[tuple[int, int, int]] = field(default_factory=list)


def natural_key(path: Path) -> list[Any]:
    parts = re.split(r"(\d+)", path.name)
    return [int(part) if part.isdigit() else part.lower() for part in parts]


class DisjointSet:
    def __init__(self) -> None:
        self.parent: list[int] = []
        self.rank: list[int] = []

    def add(self) -> int:
        ident = len(self.parent)
        self.parent.append(ident)
        self.rank.append(0)
        return ident

    def find(self, ident: int) -> int:
        parent = self.parent[ident]
        if parent != ident:
            self.parent[ident] = self.find(parent)
        return self.parent[ident]

    def union(self, left: int, right: int) -> None:
        left_root = self.find(left)
        right_root = self.find(right)
        if left_root == right_root:
            return
        if self.rank[left_root] < self.rank[right_root]:
            left_root, right_root = right_root, left_root
        self.parent[right_root] = left_root
        if self.rank[left_root] == self.rank[right_root]:
            self.rank[left_root] += 1


def connected_components(mask: np.ndarray, *, min_area: int) -> list[Component]:
    if mask.ndim != 2:
        raise ValueError("connected_components expects a 2D mask")

    height, _ = mask.shape
    dsu = DisjointSet()
    runs: list[tuple[int, int, int]] = []
    previous: list[tuple[int, int, int]] = []

    for y in range(height):
        row = mask[y]
        if not row.any():
            previous = []
            continue

        padded = np.concatenate(([False], row, [False]))
        changes = np.flatnonzero(padded[1:] != padded[:-1])
        starts = changes[0::2]
        ends = changes[1::2] - 1
        current: list[tuple[int, int, int]] = []

        prev_index = 0
        for start_raw, end_raw in zip(starts, ends):
            start = int(start_raw)
            end = int(end_raw)
            run_id = dsu.add()
            runs.append((start, end, y))
            current.append((run_id, start, end))

            while prev_index < len(previous) and previous[prev_index][2] < start - 1:
                prev_index += 1
            overlap_index = prev_index
            while overlap_index < len(previous) and previous[overlap_index][1] <= end + 1:
                dsu.union(run_id, previous[overlap_index][0])
                overlap_index += 1

        previous = current

    aggregates: dict[int, dict[str, Any]] = {}
    for run_id, (start, end, y) in enumerate(runs):
        root = dsu.find(run_id)
        width = end - start + 1
        center_x_sum = (start + end) * width / 2.0
        entry = aggregates.setdefault(
            root,
            {
                "area": 0.0,
                "left": float(start),
                "top": float(y),
                "right": float(end + 1),
                "bottom": float(y + 1),
                "sum_x": 0.0,
                "sum_y": 0.0,
                "runs": [],
            },
        )
        entry["area"] += width
        entry["left"] = min(entry["left"], start)
        entry["top"] = min(entry["top"], y)
        entry["right"] = max(entry["right"], end + 1)
        entry["bottom"] = max(entry["bottom"], y + 1)
        entry["sum_x"] += center_x_sum
        entry["sum_y"] += y * width
        entry["runs"].append((start, end, y))

    components: list[Component] = []
    for entry in aggregates.values():
        area = int(entry["area"])
        if area < min_area:
            continue
        components.append(
            Component(
                area=area,
                bbox=(
                    int(entry["left"]),
                    int(entry["top"]),
                    int(entry["right"]),
                    int(entry["bottom"]),
                ),
                centroid=(entry["sum_x"] / area, entry["sum_y"] / area),
                runs=list(entry["runs"]),
            )
        )
    components.sort(key=lambda item: item.area, reverse=True)
    return components


def clamp_bbox(
    bbox: tuple[int, int, int, int],
    *,
    width: int,
    height: int,
    padding: int,
) -> tuple[int, int, int, int]:
    left, top, right, bottom = bbox
    return (
        max(0, left - padding),
        max(0, top - padding),
        min(width, right + padding),
        min(height, bottom + padding),
    )


def restore_clamped_padding(
    crop: Image.Image,
    *,
    bbox: tuple[int, int, int, int],
    padded_bbox: tuple[int, int, int, int],
    padding: int,
) -> tuple[Image.Image, tuple[int, int, int, int]]:
    left, top, right, bottom = bbox
    padded_left, padded_top, padded_right, padded_bottom = padded_bbox
    missing = (
        max(0, padding - (left - padded_left)),
        max(0, padding - (top - padded_top)),
        max(0, padding - (padded_right - right)),
        max(0, padding - (padded_bottom - bottom)),
    )
    missing_left, missing_top, missing_right, missing_bottom = missing
    if not any(missing):
        return crop, missing
    canvas = Image.new(
        "RGBA",
        (crop.width + missing_left + missing_right, crop.height + missing_top + missing_bottom),
        (0, 0, 0, 0),
    )
    canvas.alpha_composite(crop, (missing_left, missing_top))
    return canvas, missing


def union_bbox(
    left_bbox: tuple[int, int, int, int] | None,
    right_bbox: tuple[int, int, int, int],
) -> tuple[int, int, int, int]:
    if left_bbox is None:
        return right_bbox
    return (
        min(left_bbox[0], right_bbox[0]),
        min(left_bbox[1], right_bbox[1]),
        max(left_bbox[2], right_bbox[2]),
        max(left_bbox[3], right_bbox[3]),
    )


def make_slots(width: int, height: int, *, rows: int, cols: int) -> list[Slot]:
    slots: list[Slot] = []
    for row in range(rows):
        for col in range(cols):
            slots.append(
                Slot(
                    row=row,
                    col=col,
                    anchor=((col + 0.5) * width / cols, (row + 0.5) * height / rows),
                )
            )
    return slots


def nearest_slot(component: Component, slots: list[Slot], *, cell_w: float, cell_h: float) -> Slot:
    cx, cy = component.centroid
    return min(
        slots,
        key=lambda slot: ((cx - slot.anchor[0]) / cell_w) ** 2
        + ((cy - slot.anchor[1]) / cell_h) ** 2,
    )


def add_component_to_slot(slot: Slot, component: Component) -> None:
    slot.bbox = union_bbox(slot.bbox, component.bbox)
    slot.area += component.area
    slot.components += 1
    slot.runs.extend(component.runs)


def bbox_gap_and_overlap(
    left_bbox: tuple[int, int, int, int],
    right_bbox: tuple[int, int, int, int],
) -> tuple[int, int, int, int]:
    left_a, top_a, right_a, bottom_a = left_bbox
    left_b, top_b, right_b, bottom_b = right_bbox
    x_gap = max(0, max(left_a - right_b, left_b - right_a))
    y_gap = max(0, max(top_a - bottom_b, top_b - bottom_a))
    x_overlap = max(0, min(right_a, right_b) - max(left_a, left_b))
    y_overlap = max(0, min(bottom_a, bottom_b) - max(top_a, top_b))
    return x_gap, y_gap, x_overlap, y_overlap


def satellite_score(
    component: Component,
    slot: Slot,
    *,
    cell_w: float,
    cell_h: float,
) -> float:
    if slot.bbox is None:
        cx, cy = component.centroid
        return 1000.0 + ((cx - slot.anchor[0]) / cell_w) ** 2 + ((cy - slot.anchor[1]) / cell_h) ** 2

    x_gap, y_gap, x_overlap, y_overlap = bbox_gap_and_overlap(component.bbox, slot.bbox)
    cx, cy = component.centroid
    anchor_dx = abs(cx - slot.anchor[0]) / cell_w
    anchor_dy = abs(cy - slot.anchor[1]) / cell_h
    score = (x_gap / cell_w) * 3.0 + (y_gap / cell_h) * 2.0 + anchor_dx * 0.15 + anchor_dy * 0.15
    if x_overlap > 0:
        score -= min(0.75, x_overlap / max(1, component.bbox[2] - component.bbox[0]))
    if y_overlap > 0:
        score -= min(0.5, y_overlap / max(1, component.bbox[3] - component.bbox[1]))
    return score


def assign_components_to_slots(
    components: list[Component],
    slots: list[Slot],
    *,
    cell_w: float,
    cell_h: float,
) -> None:
    claimed_slots: set[tuple[int, int]] = set()
    satellites: list[Component] = []
    expected_slots = len(slots)

    for component in components:
        primary_slot = nearest_slot(component, slots, cell_w=cell_w, cell_h=cell_h)
        slot_key = (primary_slot.row, primary_slot.col)
        if len(claimed_slots) < expected_slots and slot_key not in claimed_slots:
            add_component_to_slot(primary_slot, component)
            claimed_slots.add(slot_key)
        else:
            satellites.append(component)

    for component in satellites:
        slot = min(slots, key=lambda candidate: satellite_score(component, candidate, cell_w=cell_w, cell_h=cell_h))
        add_component_to_slot(slot, component)


def border_is_dark(rgba: np.ndarray) -> bool:
    rgb = rgba[:, :, :3]
    border = np.concatenate([rgb[0], rgb[-1], rgb[:, 0], rgb[:, -1]], axis=0)
    return float(np.median(border.max(axis=1))) < 64.0


def dark_background_cutout(
    input_path: Path,
    source: Image.Image,
    *,
    black_threshold: int,
    black_dilate: int,
) -> tuple[Image.Image, Image.Image, Image.Image, str]:
    arr = np.asarray(source.convert("RGBA"), dtype=np.uint8)
    rgb = arr[:, :, :3]
    existing_alpha = arr[:, :, 3]

    cutout = run_cutout(
        input_path,
        CutoutOptions(
            engine="classic",
            preset="fast",
            tolerance=10.0,
            edge_softness=0.4,
            alpha_floor=8,
            alpha_ceiling=250,
            decontaminate=False,
        ),
    )
    cutout_alpha = np.asarray(cutout.alpha.convert("L"), dtype=np.uint8)

    seed = (rgb.max(axis=2) > black_threshold) & (existing_alpha > 0)
    seed_image = Image.fromarray(np.where(seed, 255, 0).astype(np.uint8), "L")
    dilated_image = seed_image
    if black_dilate > 0:
        dilated_image = dilated_image.filter(ImageFilter.MaxFilter(black_dilate * 2 + 1))
    dilated = np.asarray(dilated_image, dtype=np.uint8)

    alpha = np.maximum(cutout_alpha, dilated)
    alpha = np.where(existing_alpha > 0, alpha, 0).astype(np.uint8)
    output = source.convert("RGBA")
    output.putalpha(Image.fromarray(alpha, "L"))
    return output, Image.fromarray(alpha, "L"), seed_image, "dark-bg"


def cutout_background(
    input_path: Path,
    *,
    engine: str,
    preset: str,
    tolerance: float | None,
    edge_softness: float | None,
) -> tuple[Image.Image, Image.Image, Image.Image, str]:
    result = run_cutout(
        input_path,
        CutoutOptions(
            engine=engine,
            preset=preset,
            tolerance=tolerance,
            edge_softness=edge_softness,
            bg_palette_size=6,
            alpha_floor=16,
            alpha_ceiling=250,
            decontaminate=True,
        ),
    )
    alpha = result.alpha.convert("L")
    return result.rgba.convert("RGBA"), alpha, alpha, str(result.diagnostics.get("engine", engine))


def alpha_from_source(source: Image.Image) -> tuple[Image.Image, Image.Image, Image.Image, str]:
    rgba = source.convert("RGBA")
    alpha = rgba.getchannel("A")
    return rgba, alpha, alpha, "alpha"


def build_foreground(
    input_path: Path,
    *,
    mask_mode: str,
    cutout_engine: str,
    cutout_preset: str,
    tolerance: float | None,
    edge_softness: float | None,
    black_threshold: int,
    black_dilate: int,
) -> tuple[Image.Image, Image.Image, Image.Image, str]:
    source = Image.open(input_path).convert("RGBA")
    source_arr = np.asarray(source, dtype=np.uint8)
    alpha = source_arr[:, :, 3]

    if mask_mode == "alpha":
        return alpha_from_source(source)
    if mask_mode == "dark-bg":
        return dark_background_cutout(
            input_path,
            source,
            black_threshold=black_threshold,
            black_dilate=black_dilate,
        )
    if mask_mode == "cutout":
        return cutout_background(
            input_path,
            engine=cutout_engine,
            preset=cutout_preset,
            tolerance=tolerance,
            edge_softness=edge_softness,
        )
    if mask_mode != "auto":
        raise ValueError(f"Unsupported mask mode: {mask_mode}")

    if int(alpha.min()) < 255:
        return alpha_from_source(source)
    if border_is_dark(source_arr):
        return dark_background_cutout(
            input_path,
            source,
            black_threshold=black_threshold,
            black_dilate=black_dilate,
        )
    return cutout_background(
        input_path,
        engine=cutout_engine,
        preset=cutout_preset,
        tolerance=tolerance,
        edge_softness=edge_softness,
    )


def checkerboard(size: tuple[int, int], tile: int = 24) -> Image.Image:
    width, height = size
    image = Image.new("RGBA", size, (238, 238, 238, 255))
    draw = ImageDraw.Draw(image)
    for y in range(0, height, tile):
        for x in range(0, width, tile):
            color = (198, 198, 198, 255) if ((x // tile) + (y // tile)) % 2 else (238, 238, 238, 255)
            draw.rectangle((x, y, x + tile - 1, y + tile - 1), fill=color)
    return image


def save_overlay(
    source: Image.Image,
    slots: list[Slot],
    output: Path,
    *,
    padding: int,
) -> None:
    preview = source.convert("RGBA")
    draw = ImageDraw.Draw(preview)
    font = ImageFont.load_default()
    colors = [
        (255, 80, 80, 255),
        (80, 180, 255, 255),
        (120, 220, 120, 255),
        (255, 190, 70, 255),
        (220, 120, 255, 255),
    ]

    for index, slot in enumerate(slots, start=1):
        if slot.bbox is None:
            continue
        color = colors[(index - 1) % len(colors)]
        left, top, right, bottom = slot.bbox
        draw.rectangle((left, top, right - 1, bottom - 1), outline=color, width=3)
        label = f"{index:02d}"
        label_box = draw.textbbox((left + 4, top + 4), label, font=font)
        draw.rectangle(label_box, fill=(0, 0, 0, 180))
        draw.text((left + 4, top + 4), label, fill=color, font=font)

    output.parent.mkdir(parents=True, exist_ok=True)
    preview.save(output)


def save_repacked(
    crops: list[tuple[int, Image.Image]],
    output: Path,
    *,
    rows: int,
    cols: int,
    tile_padding: int,
    checker_preview: Path | None,
) -> None:
    if not crops:
        return
    crop_by_index = {index: crop for index, crop in crops}
    max_width = max(crop.width for _, crop in crops)
    max_height = max(crop.height for _, crop in crops)
    tile_width = max_width + tile_padding * 2
    tile_height = max_height + tile_padding * 2
    sheet = Image.new("RGBA", (cols * tile_width, rows * tile_height), (0, 0, 0, 0))

    for index in range(1, rows * cols + 1):
        crop = crop_by_index.get(index)
        if crop is None:
            continue
        slot_index = index - 1
        col = slot_index % cols
        row = slot_index // cols
        x = col * tile_width + (tile_width - crop.width) // 2
        y = row * tile_height + (tile_height - crop.height) // 2
        sheet.alpha_composite(crop, (x, y))

    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output)
    if checker_preview is not None:
        checker = checkerboard(sheet.size)
        checker.alpha_composite(sheet)
        checker_preview.parent.mkdir(parents=True, exist_ok=True)
        checker.convert("RGB").save(checker_preview, quality=95)


def save_contact_sheet(
    previews: list[Path],
    output: Path,
    *,
    columns: int = 3,
    max_preview_size: tuple[int, int] = (640, 640),
) -> None:
    if not previews:
        return
    font = ImageFont.load_default()
    label_height = 28
    cell_width = max_preview_size[0]
    cell_height = max_preview_size[1] + label_height
    rows = math.ceil(len(previews) / columns)
    contact = Image.new("RGB", (columns * cell_width, rows * cell_height), (34, 34, 34))
    draw = ImageDraw.Draw(contact)

    for index, preview_path in enumerate(previews):
        with Image.open(preview_path) as source:
            preview = source.convert("RGB")
        preview.thumbnail(max_preview_size, Image.Resampling.LANCZOS)
        col = index % columns
        row = index // columns
        cell_x = col * cell_width
        cell_y = row * cell_height
        image_x = cell_x + (cell_width - preview.width) // 2
        image_y = cell_y + (max_preview_size[1] - preview.height) // 2
        contact.paste(preview, (image_x, image_y))
        label = preview_path.name.removesuffix("_repacked_preview.jpg")
        draw.text((cell_x + 8, cell_y + max_preview_size[1] + 8), label, fill=(235, 235, 235), font=font)

    output.parent.mkdir(parents=True, exist_ok=True)
    contact.save(output, quality=92)


def validate_clean_dir(path: Path, *, input_dir: Path) -> Path:
    resolved = path.resolve()
    input_resolved = input_dir.resolve()
    forbidden = {
        Path("/").resolve(),
        Path.cwd().resolve(),
        Path.home().resolve(),
        input_resolved,
    }
    if resolved in forbidden:
        raise RuntimeError(f"Refusing to clean unsafe output directory: {path}")
    if input_resolved in resolved.parents:
        raise RuntimeError(f"Refusing to clean an output directory inside the input tree: {path}")
    if resolved in input_resolved.parents:
        raise RuntimeError(f"Refusing to clean an ancestor of the input directory: {path}")
    if path.exists() and path.is_symlink():
        raise RuntimeError(f"Refusing to clean symlink output directory: {path}")
    if path.exists() and not path.is_dir():
        raise RuntimeError(f"Output path exists and is not a directory: {path}")
    return resolved


def validate_clean_targets(paths: list[Path], *, input_dir: Path) -> None:
    resolved_paths = [(path, validate_clean_dir(path, input_dir=input_dir)) for path in paths]
    for index, (left_path, left_resolved) in enumerate(resolved_paths):
        for right_path, right_resolved in resolved_paths[index + 1 :]:
            if (
                left_resolved == right_resolved
                or left_resolved in right_resolved.parents
                or right_resolved in left_resolved.parents
            ):
                raise RuntimeError(
                    "Refusing to clean overlapping output directories: "
                    f"{left_path} and {right_path}"
                )


def safe_clean_dir(path: Path, *, input_dir: Path) -> None:
    validate_clean_dir(path, input_dir=input_dir)
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


def split_sheet(
    input_path: Path,
    *,
    args: argparse.Namespace,
    start_index: int,
) -> tuple[list[dict[str, Any]], list[str], int]:
    foreground, alpha, assignment_alpha, engine_used = build_foreground(
        input_path,
        mask_mode=args.mask_mode,
        cutout_engine=args.cutout_engine,
        cutout_preset=args.cutout_preset,
        tolerance=args.tolerance,
        edge_softness=args.edge_softness,
        black_threshold=args.black_threshold,
        black_dilate=args.black_dilate,
    )
    source = Image.open(input_path).convert("RGBA")
    alpha_arr = np.asarray(alpha.convert("L"), dtype=np.uint8)
    assignment_arr = np.asarray(assignment_alpha.convert("L"), dtype=np.uint8)
    mask = assignment_arr > args.alpha_threshold
    components = connected_components(mask, min_area=args.min_component_area)

    width, height = foreground.size
    slots = make_slots(width, height, rows=args.rows, cols=args.cols)
    cell_w = width / args.cols
    cell_h = height / args.rows

    assign_components_to_slots(components, slots, cell_w=cell_w, cell_h=cell_h)

    warnings: list[str] = []
    crops: list[tuple[int, Image.Image]] = []
    records: list[dict[str, Any]] = []
    next_index = start_index
    expected = args.rows * args.cols
    filled = sum(1 for slot in slots if slot.bbox is not None)
    if filled != expected:
        warnings.append(f"{input_path.name}: detected {filled}/{expected} occupied slots")

    for slot_index, slot in enumerate(slots, start=1):
        if slot.bbox is None:
            continue
        padded = clamp_bbox(slot.bbox, width=width, height=height, padding=args.padding)
        crop = foreground.crop(padded)
        left, top, right, bottom = padded
        slot_alpha = np.zeros((bottom - top, right - left), dtype=np.uint8)
        for run_start, run_end, run_y in slot.runs:
            if run_y < top or run_y >= bottom:
                continue
            x0 = max(run_start, left)
            x1 = min(run_end + 1, right)
            if x0 >= x1:
                continue
            if engine_used == "dark-bg":
                slot_alpha[run_y - top, x0 - left : x1 - left] = assignment_arr[run_y, x0:x1]
            else:
                slot_alpha[run_y - top, x0 - left : x1 - left] = alpha_arr[run_y, x0:x1]
        if engine_used == "dark-bg" and args.black_dilate > 0:
            slot_alpha_image = Image.fromarray(slot_alpha, "L")
            slot_alpha_image = slot_alpha_image.filter(ImageFilter.MaxFilter(args.black_dilate * 2 + 1))
            slot_alpha = np.asarray(slot_alpha_image, dtype=np.uint8)
        crop.putalpha(Image.fromarray(slot_alpha, "L"))
        crop_arr = np.asarray(crop, dtype=np.uint8).copy()
        crop_arr[slot_alpha == 0, :3] = 0
        crop = Image.fromarray(crop_arr, "RGBA")
        crop, restored_padding = restore_clamped_padding(
            crop,
            bbox=slot.bbox,
            padded_bbox=padded,
            padding=args.padding,
        )
        name = f"{args.prefix}_{next_index:0{args.digits}d}.png"
        output = args.output_dir / name
        output.parent.mkdir(parents=True, exist_ok=True)
        crop.save(output)
        crops.append((slot_index, crop))
        records.append(
            {
                "index": next_index,
                "file": str(output),
                "source": str(input_path),
                "source_slot": slot_index,
                "row": slot.row + 1,
                "col": slot.col + 1,
                "bbox": list(slot.bbox),
                "padded_bbox": list(padded),
                "restored_padding": list(restored_padding),
                "output_size": [crop.width, crop.height],
                "area": slot.area,
                "components": slot.components,
                "mask_engine": engine_used,
            }
        )
        next_index += 1

    if args.preview_dir is not None:
        save_overlay(
            source,
            [
                Slot(
                    row=slot.row,
                    col=slot.col,
                    anchor=slot.anchor,
                    bbox=clamp_bbox(slot.bbox, width=width, height=height, padding=args.padding)
                    if slot.bbox is not None
                    else None,
                    area=slot.area,
                    components=slot.components,
                )
                for slot in slots
            ],
            args.preview_dir / f"{input_path.stem}_boxes.png",
            padding=args.padding,
        )

    if args.repack_dir is not None:
        save_repacked(
            crops,
            args.repack_dir / f"{input_path.stem}_repacked.png",
            rows=args.rows,
            cols=args.cols,
            tile_padding=args.tile_padding,
            checker_preview=args.preview_dir / f"{input_path.stem}_repacked_preview.jpg"
            if args.preview_dir is not None
            else None,
        )

    return records, warnings, next_index


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Split sprite sheets by masking foreground objects, assigning them to grid slots, and cropping with padding.",
    )
    parser.add_argument("input_dir", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--glob", default="*.png")
    parser.add_argument("--rows", type=int, required=True)
    parser.add_argument("--cols", type=int, required=True)
    parser.add_argument("--prefix", default="sprite")
    parser.add_argument("--start-index", type=int, default=1)
    parser.add_argument("--digits", type=int, default=3)
    parser.add_argument("--padding", type=int, default=28)
    parser.add_argument("--tile-padding", type=int, default=64)
    parser.add_argument("--alpha-threshold", type=int, default=16)
    parser.add_argument("--min-component-area", type=int, default=30)
    parser.add_argument("--black-threshold", type=int, default=18)
    parser.add_argument("--black-dilate", type=int, default=2)
    parser.add_argument("--mask-mode", choices=("auto", "alpha", "dark-bg", "cutout"), default="auto")
    parser.add_argument("--cutout-engine", choices=("auto", "classic", "birefnet"), default="classic")
    parser.add_argument("--cutout-preset", choices=("fast", "balanced", "pro"), default="balanced")
    parser.add_argument("--tolerance", type=float, default=None)
    parser.add_argument("--edge-softness", type=float, default=None)
    parser.add_argument("--repack-dir", type=Path)
    parser.add_argument("--preview-dir", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--clean-output", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.rows <= 0 or args.cols <= 0:
        parser.error("--rows and --cols must be positive")
    if not args.input_dir.is_dir():
        parser.error(f"Input directory not found: {args.input_dir}")

    if args.clean_output:
        clean_targets = [args.output_dir]
        if args.repack_dir is not None:
            clean_targets.append(args.repack_dir)
        if args.preview_dir is not None:
            clean_targets.append(args.preview_dir)
        validate_clean_targets(clean_targets, input_dir=args.input_dir)
        for target in clean_targets:
            safe_clean_dir(target, input_dir=args.input_dir)
    else:
        args.output_dir.mkdir(parents=True, exist_ok=True)
        if args.repack_dir is not None:
            args.repack_dir.mkdir(parents=True, exist_ok=True)
        if args.preview_dir is not None:
            args.preview_dir.mkdir(parents=True, exist_ok=True)

    inputs = sorted(args.input_dir.glob(args.glob), key=natural_key)
    if not inputs:
        parser.error(f"No files matched {args.glob} in {args.input_dir}")

    all_records: list[dict[str, Any]] = []
    all_warnings: list[str] = []
    next_index = args.start_index
    for input_path in inputs:
        records, warnings, next_index = split_sheet(input_path, args=args, start_index=next_index)
        all_records.extend(records)
        all_warnings.extend(warnings)
        print(f"{input_path.name}: wrote {len(records)} sprites")
        for warning in warnings:
            print(f"Warning: {warning}", file=sys.stderr)

    if args.preview_dir is not None and args.repack_dir is not None:
        repacked_previews = [
            args.preview_dir / f"{input_path.stem}_repacked_preview.jpg" for input_path in inputs
        ]
        save_contact_sheet(
            repacked_previews,
            args.preview_dir / "_repacked_contact_sheet.jpg",
        )

    manifest = {
        "input_dir": str(args.input_dir),
        "output_dir": str(args.output_dir),
        "rows": args.rows,
        "cols": args.cols,
        "prefix": args.prefix,
        "count": len(all_records),
        "warnings": all_warnings,
        "sprites": all_records,
    }
    if args.manifest is not None:
        args.manifest.parent.mkdir(parents=True, exist_ok=True)
        args.manifest.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Total sprites: {len(all_records)}")
    if args.manifest is not None:
        print(f"Manifest: {args.manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
