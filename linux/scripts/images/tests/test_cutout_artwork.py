from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from cutout_engine.pipeline import run_cutout  # noqa: E402
from cutout_engine.types import CutoutOptions  # noqa: E402


class ArtworkCutoutTests(unittest.TestCase):
    def options(self, **overrides) -> CutoutOptions:
        values = {
            "engine": "artwork",
            "background_model": "flat",
            "matte_low": 0.5,
            "matte_high": 2.0,
            "edge_guard": 0,
            "component_filter": True,
            "alpha_floor": 0,
            "alpha_ceiling": 255,
        }
        values.update(overrides)
        return CutoutOptions(**values)

    def test_removes_enclosed_paper_inside_line_art(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            source = Path(temp_dir) / "ring.png"
            image = Image.new("RGB", (96, 96), (244, 232, 210))
            ImageDraw.Draw(image).ellipse((18, 18, 78, 78), outline=(22, 45, 36), width=5)
            image.save(source)

            result = run_cutout(source, self.options())
            alpha = np.asarray(result.alpha)

            self.assertEqual(int(alpha[48, 48]), 0)
            self.assertEqual(int(alpha[0, 0]), 0)
            self.assertGreater(int(alpha[18, 48]), 200)

    def test_quadratic_model_removes_a_smooth_paper_field(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            source = Path(temp_dir) / "field.png"
            y, x = np.mgrid[0:128, 0:128]
            xn = (x - 63.5) / 63.5
            yn = (y - 63.5) / 63.5
            base = 232.0 + 3.0 * xn - 2.0 * yn + 2.0 * xn * xn
            rgb = np.stack([base + 8.0, base, base - 18.0], axis=-1)
            rgb = np.clip(rgb, 0, 255).astype(np.uint8)
            rgb[28:100, 62:66] = (18, 48, 36)
            Image.fromarray(rgb, "RGB").save(source)

            result = run_cutout(
                source,
                self.options(background_model="quadratic", matte_low=1.0, matte_high=3.0),
            )
            alpha = np.asarray(result.alpha)

            self.assertEqual(int(alpha[4, 4]), 0)
            self.assertGreater(int(alpha[50, 63]), 200)
            self.assertLess(int(np.count_nonzero(alpha[:, :40])), 8)

    def test_unmatted_result_recomposes_on_the_estimated_paper(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            source = Path(temp_dir) / "composite.png"
            background = Image.new("RGBA", (80, 80), (244, 232, 210, 255))
            foreground = Image.new("RGBA", (80, 80), (0, 0, 0, 0))
            ImageDraw.Draw(foreground).rectangle((20, 20, 59, 59), fill=(20, 90, 48, 128))
            observed = Image.alpha_composite(background, foreground).convert("RGB")
            observed.save(source)

            result = run_cutout(source, self.options())
            recomposed = Image.alpha_composite(background, result.rgba).convert("RGB")
            observed_array = np.asarray(observed, dtype=np.int16)
            recomposed_array = np.asarray(recomposed, dtype=np.int16)
            error = np.abs(observed_array - recomposed_array)

            self.assertLessEqual(float(error.mean()), 0.5)
            self.assertLessEqual(int(error.max()), 2)


if __name__ == "__main__":
    unittest.main()
