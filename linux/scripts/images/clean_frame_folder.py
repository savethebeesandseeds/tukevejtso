#!/usr/bin/env python3

import argparse
import collections
import pathlib
import subprocess
import sys
from typing import Optional


TRANSPARENT_WHITE = bytes((255, 255, 255, 0))


def get_dimensions(path: pathlib.Path) -> tuple[int, int]:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=width,height",
        "-of",
        "csv=p=0:s=x",
        str(path),
    ]
    out = subprocess.check_output(cmd, text=True).strip()
    width, height = out.split("x")
    return int(width), int(height)


def read_rgba(path: pathlib.Path) -> tuple[int, int, bytes]:
    width, height = get_dimensions(path)
    cmd = [
        "ffmpeg",
        "-v",
        "error",
        "-i",
        str(path),
        "-f",
        "rawvideo",
        "-pix_fmt",
        "rgba",
        "-",
    ]
    raw = subprocess.check_output(cmd)
    expected_len = width * height * 4
    if len(raw) != expected_len:
        raise ValueError(
            f"{path}: expected {expected_len} bytes, got {len(raw)} bytes"
        )
    return width, height, raw


def write_rgba(path: pathlib.Path, width: int, height: int, raw: bytes) -> None:
    cmd = [
        "ffmpeg",
        "-y",
        "-v",
        "error",
        "-f",
        "rawvideo",
        "-pix_fmt",
        "rgba",
        "-video_size",
        f"{width}x{height}",
        "-i",
        "-",
        "-frames:v",
        "1",
        str(path),
    ]
    subprocess.run(cmd, input=raw, check=True)


def normalize_alpha(pixels: list[bytes]) -> list[bytes]:
    normalized = []
    for pixel in pixels:
        if pixel[3] < 255:
            normalized.append(TRANSPARENT_WHITE)
        else:
            normalized.append(pixel)
    return normalized


def remove_rare_opaque_colors(pixels: list[bytes], min_count: int) -> tuple[list[bytes], int]:
    opaque_counts = collections.Counter(pixel for pixel in pixels if pixel[3] == 255)

    cleaned = []
    removed_colors = 0
    seen_removed = set()
    for pixel in pixels:
        if pixel[3] == 255 and opaque_counts[pixel] < min_count:
            cleaned.append(TRANSPARENT_WHITE)
            if pixel not in seen_removed:
                removed_colors += 1
                seen_removed.add(pixel)
        else:
            cleaned.append(pixel)

    return cleaned, removed_colors


def smooth_edge_noise(
    pixels: list[bytes],
    width: int,
    height: int,
    passes: int,
    min_majority: int,
    min_margin: int,
) -> tuple[list[bytes], int]:
    total_changes = 0

    for _ in range(passes):
        source = pixels[:]
        updated = source[:]
        pass_changes = 0

        for y in range(height):
            for x in range(width):
                idx = y * width + x
                pixel = source[idx]
                if pixel[3] != 255:
                    continue

                opaque_neighbors = []
                has_transparent_neighbor = False
                for ny in range(max(0, y - 1), min(height, y + 2)):
                    for nx in range(max(0, x - 1), min(width, x + 2)):
                        if nx == x and ny == y:
                            continue
                        neighbor = source[ny * width + nx]
                        if neighbor[3] == 255:
                            opaque_neighbors.append(neighbor)
                        else:
                            has_transparent_neighbor = True

                if not has_transparent_neighbor or not opaque_neighbors:
                    continue

                neighbor_counts = collections.Counter(opaque_neighbors)
                dominant_color, dominant_count = neighbor_counts.most_common(1)[0]
                current_count = neighbor_counts.get(pixel, 0)

                if dominant_color != pixel and dominant_count >= min_majority:
                    if dominant_count - current_count >= min_margin:
                        updated[idx] = dominant_color
                        pass_changes += 1

        pixels = updated
        total_changes += pass_changes
        if pass_changes == 0:
            break

    return pixels, total_changes


def process_file(
    src: pathlib.Path,
    dst: pathlib.Path,
    min_count: Optional[int],
    edge_passes: int,
    edge_min_majority: int,
    edge_min_margin: int,
) -> tuple[int, int, int]:
    width, height, raw = read_rgba(src)
    pixels = [raw[i : i + 4] for i in range(0, len(raw), 4)]
    pixels = normalize_alpha(pixels)

    removed_colors = 0
    if min_count is not None:
        pixels, removed_colors = remove_rare_opaque_colors(pixels, min_count)

    edge_changes = 0
    if edge_passes > 0:
        pixels, edge_changes = smooth_edge_noise(
            pixels,
            width,
            height,
            edge_passes,
            edge_min_majority,
            edge_min_margin,
        )

    cleaned = b"".join(pixels)
    dst.parent.mkdir(parents=True, exist_ok=True)
    write_rgba(dst, width, height, cleaned)
    return len(raw) // 4, removed_colors, edge_changes


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Normalize semi-transparent pixels to white transparent and remove "
            "rare opaque colors by turning them transparent."
        )
    )
    parser.add_argument("input_dir", type=pathlib.Path)
    parser.add_argument("output_dir", type=pathlib.Path)
    parser.add_argument("--glob", default="frame_*.png")
    parser.add_argument(
        "--min-count",
        type=int,
        default=None,
        help="Turn opaque colors with fewer than this many pixels transparent.",
    )
    parser.add_argument(
        "--edge-passes",
        type=int,
        default=0,
        help="Run this many edge-only majority smoothing passes.",
    )
    parser.add_argument(
        "--edge-min-majority",
        type=int,
        default=5,
        help="Minimum matching opaque neighbors needed to replace an edge pixel.",
    )
    parser.add_argument(
        "--edge-min-margin",
        type=int,
        default=3,
        help="Required lead over the current color among neighbors.",
    )
    args = parser.parse_args()

    files = sorted(args.input_dir.glob(args.glob))
    if not files:
        print(f"No files matched {args.glob} in {args.input_dir}", file=sys.stderr)
        return 1

    total_removed = 0
    total_edge_changes = 0
    for src in files:
        dst = args.output_dir / src.name
        _, removed_colors, edge_changes = process_file(
            src,
            dst,
            args.min_count,
            args.edge_passes,
            args.edge_min_majority,
            args.edge_min_margin,
        )
        total_removed += removed_colors
        total_edge_changes += edge_changes

    print(
        f"processed={len(files)} output_dir={args.output_dir} "
        f"min_count={args.min_count} removed_color_entries={total_removed} "
        f"edge_passes={args.edge_passes} edge_pixel_changes={total_edge_changes}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
