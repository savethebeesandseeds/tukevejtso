from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from split_sprite_sheets import (  # noqa: E402
    Component,
    Slot,
    assign_components_to_slots,
    restore_clamped_padding,
    safe_clean_dir,
    save_contact_sheet,
    validate_clean_targets,
)


class CleanupSafetyTests(unittest.TestCase):
    def test_rejects_cleaning_input_ancestor(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            input_dir = root / "miscellaneous" / "originals"
            input_dir.mkdir(parents=True)

            with self.assertRaisesRegex(RuntimeError, "ancestor of the input"):
                safe_clean_dir(root / "miscellaneous", input_dir=input_dir)

            self.assertTrue(input_dir.is_dir())

    def test_rejects_cleaning_inside_input_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            input_dir = Path(temp_dir) / "originals"
            input_dir.mkdir()

            with self.assertRaisesRegex(RuntimeError, "inside the input tree"):
                safe_clean_dir(input_dir / "split", input_dir=input_dir)

    def test_rejects_overlapping_output_targets_before_cleaning(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            input_dir = root / "originals"
            output_dir = root / "review"
            nested_preview = output_dir / "previews"
            input_dir.mkdir()
            output_dir.mkdir()
            sentinel = output_dir / "keep.txt"
            sentinel.write_text("keep", encoding="utf-8")

            with self.assertRaisesRegex(RuntimeError, "overlapping output directories"):
                validate_clean_targets([output_dir, nested_preview], input_dir=input_dir)

            self.assertTrue(sentinel.is_file())

    def test_cleans_safe_sibling_output(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            input_dir = root / "originals"
            output_dir = root / "split"
            input_dir.mkdir()
            output_dir.mkdir()
            (output_dir / "old.txt").write_text("old", encoding="utf-8")

            safe_clean_dir(output_dir, input_dir=input_dir)

            self.assertTrue(output_dir.is_dir())
            self.assertEqual(list(output_dir.iterdir()), [])


class ComponentAssignmentTests(unittest.TestCase):
    def test_detached_satellite_follows_nearest_primary_bbox(self) -> None:
        slots = [
            Slot(row=0, col=0, anchor=(25.0, 25.0)),
            Slot(row=0, col=1, anchor=(75.0, 25.0)),
        ]
        components = [
            Component(area=400, bbox=(10, 10, 30, 30), centroid=(20.0, 20.0), runs=[]),
            Component(area=400, bbox=(65, 10, 85, 30), centroid=(75.0, 20.0), runs=[]),
            Component(area=20, bbox=(82, 12, 88, 18), centroid=(85.0, 15.0), runs=[]),
        ]

        assign_components_to_slots(components, slots, cell_w=50.0, cell_h=50.0)

        self.assertEqual(slots[0].components, 1)
        self.assertEqual(slots[1].components, 2)
        self.assertEqual(slots[1].bbox, (65, 10, 88, 30))


class CropPaddingTests(unittest.TestCase):
    def test_restores_padding_lost_at_source_edge(self) -> None:
        from PIL import Image

        crop = Image.new("RGBA", (42, 42), (255, 0, 0, 255))
        restored, missing = restore_clamped_padding(
            crop,
            bbox=(0, 10, 10, 20),
            padded_bbox=(0, 0, 42, 42),
            padding=32,
        )

        self.assertEqual(missing, (32, 22, 0, 10))
        self.assertEqual(restored.size, (74, 74))
        self.assertEqual(restored.getpixel((0, 0)), (0, 0, 0, 0))
        self.assertEqual(restored.getpixel((32, 22)), (255, 0, 0, 255))


class ContactSheetTests(unittest.TestCase):
    def test_writes_combined_preview(self) -> None:
        from PIL import Image

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            previews = []
            for index, color in enumerate(((255, 0, 0), (0, 255, 0)), start=1):
                preview = root / f"sheet-{index}_repacked_preview.jpg"
                Image.new("RGB", (80, 60), color).save(preview)
                previews.append(preview)
            output = root / "_repacked_contact_sheet.jpg"

            save_contact_sheet(previews, output, columns=2, max_preview_size=(100, 100))

            self.assertTrue(output.is_file())
            with Image.open(output) as contact:
                self.assertEqual(contact.size, (200, 128))


if __name__ == "__main__":
    unittest.main()
