#!/usr/bin/env python3

import argparse
import pathlib
import subprocess
import sys
from collections import deque
from collections import Counter
from typing import Optional


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
MARKED = (0, 0, 0, 255)


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


def pixels_to_mask(pixels: list[tuple[int, int, int, int]]) -> list[bool]:
    return [pixel[3] == 255 for pixel in pixels]


def neighbors8(width: int, height: int, x: int, y: int):
    for ny in range(max(0, y - 1), min(height, y + 2)):
        for nx in range(max(0, x - 1), min(width, x + 2)):
            if nx == x and ny == y:
                continue
            yield nx, ny


def connected_component(
    mask: list[bool], width: int, height: int, start_idx: int, target_value: bool, visited: list[bool]
) -> tuple[list[int], bool]:
    q = deque([start_idx])
    visited[start_idx] = True
    component = []
    touches_border = False

    while q:
        idx = q.popleft()
        component.append(idx)
        x = idx % width
        y = idx // width
        if x == 0 or y == 0 or x == width - 1 or y == height - 1:
            touches_border = True

        for nx, ny in neighbors8(width, height, x, y):
            nidx = ny * width + nx
            if visited[nidx] or mask[nidx] != target_value:
                continue
            visited[nidx] = True
            q.append(nidx)

    return component, touches_border


def color_component(
    pixels: list[tuple[int, int, int, int]],
    width: int,
    height: int,
    start_idx: int,
    visited: list[bool],
) -> list[int]:
    target = pixels[start_idx]
    q = deque([start_idx])
    visited[start_idx] = True
    component = []

    while q:
        idx = q.popleft()
        component.append(idx)
        x = idx % width
        y = idx // width

        for nx, ny in neighbors8(width, height, x, y):
            nidx = ny * width + nx
            if visited[nidx] or pixels[nidx] != target:
                continue
            visited[nidx] = True
            q.append(nidx)

    return component


def fill_small_holes(mask: list[bool], width: int, height: int, max_size: int) -> list[bool]:
    visited = [False] * len(mask)
    out = mask[:]

    for idx, value in enumerate(mask):
        if visited[idx] or value:
            continue
        component, touches_border = connected_component(mask, width, height, idx, False, visited)
        if not touches_border and len(component) <= max_size:
            for cidx in component:
                out[cidx] = True

    return out


def majority_smooth(mask: list[bool], width: int, height: int, iterations: int) -> list[bool]:
    current = mask[:]
    for _ in range(iterations):
        updated = current[:]
        for y in range(height):
            for x in range(width):
                idx = y * width + x
                count = 1 if current[idx] else 0
                for nx, ny in neighbors8(width, height, x, y):
                    if current[ny * width + nx]:
                        count += 1
                if count >= 5:
                    updated[idx] = True
                elif count <= 3:
                    updated[idx] = False
        current = updated
    return current


def apply_mask(
    pixels: list[tuple[int, int, int, int]], mask: list[bool]
) -> list[tuple[int, int, int, int]]:
    out = []
    for pixel, keep in zip(pixels, mask):
        if keep:
            out.append((pixel[0], pixel[1], pixel[2], 255))
        else:
            out.append(TRANSPARENT)
    return out


def palette_distance(a: tuple[int, int, int, int], b: tuple[int, int, int, int]) -> int:
    return (
        (a[0] - b[0]) ** 2 +
        (a[1] - b[1]) ** 2 +
        (a[2] - b[2]) ** 2
    )


def snap_to_allowed_palette(
    pixels: list[tuple[int, int, int, int]]
) -> list[tuple[int, int, int, int]]:
    snapped = []
    for pixel in pixels:
        if pixel[3] == 0:
            snapped.append(TRANSPARENT)
            continue
        best = min(OPAQUE_ALLOWED, key=lambda color: palette_distance(pixel, color))
        snapped.append(best)
    return snapped


def mark_small_color_islands(
    pixels: list[tuple[int, int, int, int]], width: int, height: int, max_area: int
) -> tuple[list[tuple[int, int, int, int]], int]:
    visited = [False] * len(pixels)
    out = pixels[:]
    marked = 0

    for idx, pixel in enumerate(pixels):
        if visited[idx] or pixel[3] == 0:
            continue
        component = color_component(pixels, width, height, idx, visited)
        if len(component) < max_area:
            for cidx in component:
                out[cidx] = MARKED
                marked += 1

    return out, marked


def kernel_samples(
    pixels: list[tuple[int, int, int, int]], width: int, height: int, x: int, y: int, radius: int
) -> list[tuple[int, int, int, int]]:
    samples = []
    for ny in range(max(0, y - radius), min(height, y + radius + 1)):
        for nx in range(max(0, x - radius), min(width, x + radius + 1)):
            samples.append(pixels[ny * width + nx])
    return samples


def select_allowed_mode(
    samples: list[tuple[int, int, int, int]]
) -> Optional[tuple[int, int, int, int]]:
    allowed = [sample for sample in samples if sample in OPAQUE_ALLOWED_SET]
    if not allowed:
        return None

    counts = Counter(allowed).most_common()
    top_count = counts[0][1]
    top_colors = [color for color, count in counts if count == top_count]
    if len(top_colors) == 1:
        return top_colors[0]
    return None


def repaint_marked_pixels(
    pixels: list[tuple[int, int, int, int]], width: int, height: int
) -> tuple[list[tuple[int, int, int, int]], int]:
    source = pixels[:]
    out = pixels[:]
    repainted = 0

    for y in range(height):
        for x in range(width):
            idx = y * width + x
            if source[idx] != MARKED:
                continue

            color = select_allowed_mode(kernel_samples(source, width, height, x, y, 1))
            if color is None:
                color = select_allowed_mode(kernel_samples(source, width, height, x, y, 2))
            if color is None:
                color = min(
                    OPAQUE_ALLOWED,
                    key=lambda candidate: sum(
                        palette_distance(sample, candidate)
                        for sample in kernel_samples(source, width, height, x, y, 2)
                        if sample in OPAQUE_ALLOWED_SET
                    ) or palette_distance((255, 255, 255, 255), candidate),
                )

            out[idx] = color
            repainted += 1

    return out, repainted


def process_file(
    src: pathlib.Path,
    dst: pathlib.Path,
    max_hole: int,
    smooth_iterations: int,
    island_area: int,
) -> tuple[int, int, int]:
    width, height, pixels = read_rgba(src)
    pixels = normalize_alpha(pixels)
    mask = pixels_to_mask(pixels)
    original_fg = sum(mask)

    mask = fill_small_holes(mask, width, height, max_hole)
    mask = majority_smooth(mask, width, height, smooth_iterations)

    cleaned = apply_mask(pixels, mask)
    cleaned = snap_to_allowed_palette(cleaned)
    cleaned, marked = mark_small_color_islands(cleaned, width, height, island_area)
    cleaned, _ = repaint_marked_pixels(cleaned, width, height)
    dst.parent.mkdir(parents=True, exist_ok=True)
    write_rgba(dst, width, height, cleaned)
    return original_fg, sum(mask), marked


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Clean a transparent frame sequence by repairing the alpha mask only."
    )
    parser.add_argument("input_dir", type=pathlib.Path)
    parser.add_argument("output_dir", type=pathlib.Path)
    parser.add_argument("--glob", default="frame_*.png")
    parser.add_argument("--max-hole", type=int, default=12)
    parser.add_argument("--smooth-iterations", type=int, default=1)
    parser.add_argument("--island-area", type=int, default=5)
    args = parser.parse_args()

    files = sorted(args.input_dir.glob(args.glob))
    if not files:
        print(f"No files matched {args.glob} in {args.input_dir}", file=sys.stderr)
        return 1

    total_before = 0
    total_after = 0
    total_marked = 0
    for src in files:
        before, after, marked = process_file(
            src,
            args.output_dir / src.name,
            args.max_hole,
            args.smooth_iterations,
            args.island_area,
        )
        total_before += before
        total_after += after
        total_marked += marked

    print(
        f"processed={len(files)} output_dir={args.output_dir} "
        f"before_fg={total_before} after_fg={total_after} "
        f"max_hole={args.max_hole} island_area={args.island_area} "
        f"marked_pixels={total_marked} "
        f"smooth_iterations={args.smooth_iterations}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
