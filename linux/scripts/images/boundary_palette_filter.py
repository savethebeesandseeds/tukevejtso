#!/usr/bin/env python3

import argparse
import math
import pathlib
import subprocess
import sys
from collections import Counter


TRANSPARENT = (255, 255, 255, 0)
OPAQUE_ALLOWED = [
    (253, 185, 20, 255),  # #FDB914
    (3, 107, 162, 255),   # #036BA2
    (43, 43, 48, 255),    # #2B2B30
    (233, 54, 43, 255),   # #E9362B
    (13, 156, 153, 255),  # #0D9C99
    (179, 67, 56, 255),   # #B34338
]
OPAQUE_ALLOWED_SET = set(OPAQUE_ALLOWED)


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
        TRANSPARENT if a < 255 else (r, g, b, 255)
        for r, g, b, a in pixels
    ]


def is_boundary(pixels: list[tuple[int, int, int, int]], width: int, height: int, x: int, y: int) -> bool:
    center = pixels[y * width + x]
    if center[3] == 0:
        return False
    for ny in range(max(0, y - 1), min(height, y + 2)):
        for nx in range(max(0, x - 1), min(width, x + 2)):
            if nx == x and ny == y:
                continue
            if pixels[ny * width + nx][3] == 0:
                return True
    return False


def palette_distance(a: tuple[int, int, int, int], b: tuple[int, int, int, int]) -> float:
    return math.sqrt(
        (a[0] - b[0]) ** 2 +
        (a[1] - b[1]) ** 2 +
        (a[2] - b[2]) ** 2
    )


def nearest_allowed(pixel: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    return min(OPAQUE_ALLOWED, key=lambda color: palette_distance(pixel, color))


def boundary_vote(
    pixels: list[tuple[int, int, int, int]], width: int, height: int, x: int, y: int, radius: int
) -> tuple[int, int, int, int]:
    center = pixels[y * width + x]
    votes = []

    for ny in range(max(0, y - radius), min(height, y + radius + 1)):
        for nx in range(max(0, x - radius), min(width, x + radius + 1)):
            if abs(nx - x) + abs(ny - y) > radius:
                continue
            sample = pixels[ny * width + nx]
            if sample in OPAQUE_ALLOWED_SET:
                votes.append(sample)

    if votes:
        counts = Counter(votes)
        top_count = max(counts.values())
        top_colors = [color for color, count in counts.items() if count == top_count]
        if len(top_colors) == 1:
            return top_colors[0]
        return min(top_colors, key=lambda color: palette_distance(center, color))

    return nearest_allowed(center)


def repair_frame(
    pixels: list[tuple[int, int, int, int]], width: int, height: int, radius: int
) -> tuple[list[tuple[int, int, int, int]], int]:
    out = pixels[:]
    changes = 0

    for y in range(height):
        for x in range(width):
            idx = y * width + x
            pixel = pixels[idx]
            if pixel[3] == 0:
                continue
            if pixel in OPAQUE_ALLOWED_SET:
                continue
            if not is_boundary(pixels, width, height, x, y):
                continue

            replacement = boundary_vote(pixels, width, height, x, y, radius)
            if replacement != pixel:
                out[idx] = replacement
                changes += 1

    return out, changes


def process_file(src: pathlib.Path, dst: pathlib.Path, radius: int) -> int:
    width, height, pixels = read_rgba(src)
    pixels = normalize_alpha(pixels)
    pixels, changes = repair_frame(pixels, width, height, radius)
    dst.parent.mkdir(parents=True, exist_ok=True)
    write_rgba(dst, width, height, pixels)
    return changes


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Repair off-palette boundary noise by voting from nearby allowed opaque colors."
    )
    parser.add_argument("input_dir", type=pathlib.Path)
    parser.add_argument("output_dir", type=pathlib.Path)
    parser.add_argument("--glob", default="frame_*.png")
    parser.add_argument("--radius", type=int, default=2)
    args = parser.parse_args()

    files = sorted(args.input_dir.glob(args.glob))
    if not files:
        print(f"No files matched {args.glob} in {args.input_dir}", file=sys.stderr)
        return 1

    total_changes = 0
    for src in files:
        total_changes += process_file(src, args.output_dir / src.name, args.radius)

    print(
        f"processed={len(files)} output_dir={args.output_dir} radius={args.radius} changes={total_changes}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
