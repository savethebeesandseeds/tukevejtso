from __future__ import annotations

from pathlib import Path


def cleanup_alpha(result, *, floor: int = 0, ceiling: int = 255):
    if floor <= 0 and ceiling >= 255:
        return result

    import numpy as np
    from PIL import Image

    alpha = np.array(result.alpha.convert("L"), dtype=np.uint8)
    if floor > 0:
        alpha[alpha <= floor] = 0
    if ceiling < 255:
        alpha[alpha >= ceiling] = 255

    alpha_image = Image.fromarray(alpha, "L")
    rgba = result.rgba.convert("RGBA")
    rgba.putalpha(alpha_image)
    hard_mask = alpha_image.point(lambda pixel: 255 if pixel >= 128 else 0, mode="L")
    result.rgba = rgba
    result.alpha = alpha_image
    result.hard_mask = hard_mask
    result.diagnostics["alpha_floor"] = floor
    result.diagnostics["alpha_ceiling"] = ceiling
    return result


def parse_color(value: str) -> tuple[int, int, int]:
    lowered = value.strip().lower()
    named = {
        "black": (0, 0, 0),
        "white": (255, 255, 255),
        "gray": (128, 128, 128),
        "grey": (128, 128, 128),
        "red": (220, 38, 38),
        "green": (22, 163, 74),
        "blue": (37, 99, 235),
    }
    if lowered in named:
        return named[lowered]
    if lowered.startswith("#"):
        lowered = lowered[1:]
    if len(lowered) != 6:
        raise ValueError(f"Unsupported color: {value}")
    return (
        int(lowered[0:2], 16),
        int(lowered[2:4], 16),
        int(lowered[4:6], 16),
    )


def composite_on_color(rgba, color: tuple[int, int, int]):
    from PIL import Image

    background = Image.new("RGBA", rgba.size, (*color, 255))
    return Image.alpha_composite(background, rgba).convert("RGB")


def checkerboard(size: tuple[int, int], tile: int = 16):
    from PIL import Image, ImageDraw

    width, height = size
    image = Image.new("RGB", size, (238, 238, 238))
    draw = ImageDraw.Draw(image)
    for y in range(0, height, tile):
        for x in range(0, width, tile):
            if ((x // tile) + (y // tile)) % 2:
                draw.rectangle((x, y, x + tile - 1, y + tile - 1), fill=(190, 190, 190))
    return image


def save_previews(rgba, output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    composite_on_color(rgba, parse_color("white")).save(output_dir / "preview_white.jpg", quality=95)
    composite_on_color(rgba, parse_color("black")).save(output_dir / "preview_black.jpg", quality=95)
    composite_on_color(rgba, parse_color("#808080")).save(output_dir / "preview_gray.jpg", quality=95)
    composite_on_color(rgba, parse_color("#2563eb")).save(output_dir / "preview_blue.jpg", quality=95)

    from PIL import Image

    board = checkerboard(rgba.size).convert("RGBA")
    Image.alpha_composite(board, rgba).convert("RGB").save(
        output_dir / "preview_checker.jpg",
        quality=95,
    )
