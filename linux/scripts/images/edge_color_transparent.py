#!/usr/bin/env python3

import argparse
import pathlib
import subprocess
import sys
from collections import Counter, deque


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


def read_rgba(path: pathlib.Path) -> tuple[int, int, bytearray]:
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
    return width, height, bytearray(subprocess.check_output(cmd))


def write_rgba(path: pathlib.Path, width: int, height: int, pixels: bytearray) -> None:
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
    subprocess.run(cmd, input=bytes(pixels), check=True)


def parse_color(value: str) -> tuple[int, int, int] | None:
    lowered = value.lower()
    if lowered == "auto":
        return None
    if lowered == "black":
        return (0, 0, 0)
    if lowered == "white":
        return (255, 255, 255)

    if lowered.startswith("#"):
        lowered = lowered[1:]
    if len(lowered) != 6:
        raise ValueError(f"Unsupported color: {value}")
    return (int(lowered[0:2], 16), int(lowered[2:4], 16), int(lowered[4:6], 16))


def border_indices(width: int, height: int):
    for x in range(width):
        yield x
        yield (height - 1) * width + x
    for y in range(1, height - 1):
        yield y * width
        yield y * width + width - 1


def choose_edge_color(pixels: bytearray, width: int, height: int) -> tuple[int, int, int]:
    counts: Counter[tuple[int, int, int]] = Counter()
    for index in border_indices(width, height):
        offset = index * 4
        if pixels[offset + 3] > 0:
            counts[(pixels[offset], pixels[offset + 1], pixels[offset + 2])] += 1
    if not counts:
        raise ValueError("Could not determine an edge color from non-transparent border pixels.")
    return counts.most_common(1)[0][0]


def close_enough(
    pixels: bytearray, index: int, target: tuple[int, int, int], tolerance: int
) -> bool:
    offset = index * 4
    if pixels[offset + 3] == 0:
        return False
    return (
        abs(pixels[offset] - target[0]) <= tolerance
        and abs(pixels[offset + 1] - target[1]) <= tolerance
        and abs(pixels[offset + 2] - target[2]) <= tolerance
    )


def neighbors(index: int, width: int, height: int, connectivity: int):
    x = index % width
    y = index // width
    if x > 0:
        yield index - 1
    if x < width - 1:
        yield index + 1
    if y > 0:
        yield index - width
    if y < height - 1:
        yield index + width

    if connectivity == 8:
        if x > 0 and y > 0:
            yield index - width - 1
        if x < width - 1 and y > 0:
            yield index - width + 1
        if x > 0 and y < height - 1:
            yield index + width - 1
        if x < width - 1 and y < height - 1:
            yield index + width + 1


def remove_edge_connected_color(
    pixels: bytearray,
    width: int,
    height: int,
    target: tuple[int, int, int],
    tolerance: int,
    connectivity: int,
    min_area: int,
) -> int:
    visited = bytearray(width * height)
    transparent = bytearray(width * height)
    removed = 0

    for index in border_indices(width, height):
        if visited[index] != 0 or not close_enough(pixels, index, target, tolerance):
            continue

        queue: deque[int] = deque([index])
        visited[index] = 1

        while queue:
            current = queue.popleft()
            if transparent[current] == 0:
                transparent[current] = 1
                removed += 1

            for next_index in neighbors(current, width, height, connectivity):
                if visited[next_index] == 0 and close_enough(pixels, next_index, target, tolerance):
                    visited[next_index] = 1
                    queue.append(next_index)

    if min_area > 0:
        for index in range(width * height):
            if visited[index] != 0 or not close_enough(pixels, index, target, tolerance):
                continue

            queue = deque([index])
            component: list[int] = []
            visited[index] = 1

            while queue:
                current = queue.popleft()
                component.append(current)

                for next_index in neighbors(current, width, height, connectivity):
                    if visited[next_index] == 0 and close_enough(pixels, next_index, target, tolerance):
                        visited[next_index] = 1
                        queue.append(next_index)

            if len(component) >= min_area:
                for current in component:
                    if transparent[current] == 0:
                        transparent[current] = 1
                        removed += 1

    for index, should_remove in enumerate(transparent):
        if should_remove:
            pixels[index * 4 + 3] = 0

    return removed


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Make only edge-connected pixels of a selected color transparent."
    )
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--color", default="auto", help="auto, black, white, or #RRGGBB")
    parser.add_argument("--tolerance", type=int, default=0)
    parser.add_argument("--connectivity", type=int, choices=(4, 8), default=4)
    parser.add_argument(
        "--min-area",
        type=int,
        default=0,
        help="also remove non-edge matching components at least this many pixels",
    )
    args = parser.parse_args()

    if args.tolerance < 0 or args.tolerance > 255:
        print("--tolerance must be between 0 and 255", file=sys.stderr)
        return 2
    if args.min_area < 0:
        print("--min-area must be 0 or greater", file=sys.stderr)
        return 2

    width, height, pixels = read_rgba(args.input)
    target = parse_color(args.color)
    if target is None:
        target = choose_edge_color(pixels, width, height)

    removed = remove_edge_connected_color(
        pixels, width, height, target, args.tolerance, args.connectivity, args.min_area
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    write_rgba(args.output, width, height, pixels)

    print(f"Output: {args.output}")
    print(f"Target: #{target[0]:02X}{target[1]:02X}{target[2]:02X}")
    print(f"Removed pixels: {removed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
