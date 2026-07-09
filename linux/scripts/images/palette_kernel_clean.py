#!/usr/bin/env python3

import argparse
import pathlib
import subprocess
import sys
from collections import Counter
from typing import Optional


ALLOWED = [
    (255, 255, 255, 0),   # transparent white
    (253, 185, 20, 255),  # #FDB914
    (3, 107, 162, 255),   # #036BA2
    (43, 43, 48, 255),    # #2B2B30
    (233, 54, 43, 255),   # #E9362B
    (13, 156, 153, 255),  # #0D9C99
    (179, 67, 56, 255),   # #B34338
]
OPAQUE_ALLOWED = [color for color in ALLOWED if color[3] == 255]


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


def read_rgba(path: pathlib.Path) -> tuple[int, int, list[tuple[int, int, int, int]]]:
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
    pixels = [
        (raw[i], raw[i + 1], raw[i + 2], raw[i + 3])
        for i in range(0, len(raw), 4)
    ]
    return width, height, pixels


def write_rgba(
    path: pathlib.Path, width: int, height: int, pixels: list[tuple[int, int, int, int]]
) -> None:
    raw = bytearray()
    for pixel in pixels:
        raw.extend(pixel)
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
    subprocess.run(cmd, input=bytes(raw), check=True)


def normalize_alpha(pixels: list[tuple[int, int, int, int]]) -> list[tuple[int, int, int, int]]:
    return [
        (255, 255, 255, 0) if a < 255 else (r, g, b, 255)
        for r, g, b, a in pixels
    ]


ALLOWED_SET = set(ALLOWED)
OPAQUE_ALLOWED_SET = set(OPAQUE_ALLOWED)


def cross_samples(
    pixels: list[tuple[int, int, int, int]], width: int, height: int, x: int, y: int, radius: int
) -> list[tuple[int, int, int, int]]:
    samples = []
    seen = set()

    for nx in range(max(0, x - radius), min(width, x + radius + 1)):
        idx = y * width + nx
        if idx not in seen:
            samples.append(pixels[idx])
            seen.add(idx)

    for ny in range(max(0, y - radius), min(height, y + radius + 1)):
        idx = ny * width + x
        if idx not in seen:
            samples.append(pixels[idx])
            seen.add(idx)

    return samples


def square_samples(
    pixels: list[tuple[int, int, int, int]], width: int, height: int, x: int, y: int, radius: int
) -> list[tuple[int, int, int, int]]:
    samples = []
    for ny in range(max(0, y - radius), min(height, y + radius + 1)):
        for nx in range(max(0, x - radius), min(width, x + radius + 1)):
            samples.append(pixels[ny * width + nx])
    return samples


def select_mode_color(
    samples: list[tuple[int, int, int, int]]
) -> Optional[tuple[int, int, int, int]]:
    allowed_samples = [sample for sample in samples if sample in OPAQUE_ALLOWED_SET]
    if not allowed_samples:
        return None

    counts = Counter(allowed_samples).most_common()
    if len(counts) == 1:
        return counts[0][0]

    top_count = counts[0][1]
    top_colors = [color for color, count in counts if count == top_count]
    if len(top_colors) == 1:
        return top_colors[0]

    return None


def resolve_cross_pixel(
    pixels: list[tuple[int, int, int, int]], width: int, height: int, x: int, y: int
) -> tuple[int, int, int, int]:
    center = pixels[y * width + x]
    if center[3] == 0:
        return (255, 255, 255, 0)

    color = select_mode_color(cross_samples(pixels, width, height, x, y, 2))
    if color is not None:
        return color

    color = select_mode_color(cross_samples(pixels, width, height, x, y, 3))
    if color is not None:
        return color

    return center


def cross_pass_mode(
    pixels: list[tuple[int, int, int, int]], width: int, height: int
) -> list[tuple[int, int, int, int]]:
    out = []
    for y in range(height):
        for x in range(width):
            out.append(resolve_cross_pixel(pixels, width, height, x, y))
    return out


def resolve_square_pixel(
    pixels: list[tuple[int, int, int, int]], width: int, height: int, x: int, y: int
) -> tuple[int, int, int, int]:
    center = pixels[y * width + x]
    if center[3] == 0:
        return (255, 255, 255, 0)

    color = select_mode_color(square_samples(pixels, width, height, x, y, 1))
    if color is not None:
        return color

    return center


def square_pass_mode(
    pixels: list[tuple[int, int, int, int]], width: int, height: int
) -> list[tuple[int, int, int, int]]:
    out = []
    for y in range(height):
        for x in range(width):
            out.append(resolve_square_pixel(pixels, width, height, x, y))
    return out


def process_file(src: pathlib.Path, dst: pathlib.Path, square_passes: int) -> None:
    width, height, pixels = read_rgba(src)
    pixels = normalize_alpha(pixels)
    pixels = cross_pass_mode(pixels, width, height)
    for _ in range(square_passes):
        pixels = normalize_alpha(pixels)
        pixels = square_pass_mode(pixels, width, height)
    dst.parent.mkdir(parents=True, exist_ok=True)
    write_rgba(dst, width, height, pixels)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Snap frames to a fixed palette using repeated 3x3 kernel averaging."
    )
    parser.add_argument("input_dir", type=pathlib.Path)
    parser.add_argument("output_dir", type=pathlib.Path)
    parser.add_argument("--glob", default="frame_*.png")
    parser.add_argument("--square-passes", type=int, default=2)
    args = parser.parse_args()

    files = sorted(args.input_dir.glob(args.glob))
    if not files:
        print(f"No files matched {args.glob} in {args.input_dir}", file=sys.stderr)
        return 1

    for src in files:
        process_file(src, args.output_dir / src.name, args.square_passes)

    print(
        f"processed={len(files)} output_dir={args.output_dir} "
        f"cross_passes=1 square_passes={args.square_passes}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
