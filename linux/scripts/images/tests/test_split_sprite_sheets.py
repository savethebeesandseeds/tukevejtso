from __future__ import annotations

import contextlib
import io
import json
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
    main,
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


class EmptySlotContractTests(unittest.TestCase):
    def run_sheet_case(
        self,
        occupied_slots: tuple[int, ...],
        *,
        empty_slots: tuple[int, ...] = (),
        sheet_count: int = 1,
    ) -> dict:
        from PIL import Image, ImageDraw

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            input_dir = root / "originals"
            input_dir.mkdir()
            for sheet_index in range(sheet_count):
                sheet = Image.new("RGBA", (96, 64), (0, 0, 0, 0))
                draw = ImageDraw.Draw(sheet)
                for slot in occupied_slots:
                    col = (slot - 1) % 3
                    row = (slot - 1) // 3
                    left = col * 32 + 8
                    top = row * 32 + 8
                    draw.rectangle((left, top, left + 15, top + 15), fill=(30, 120, 180, 255))
                sheet.save(input_dir / f"sheet-{sheet_index}.png")
            output_dir = root / "split"
            manifest_path = root / "manifest.json"
            arguments = [
                str(input_dir), str(output_dir),
                "--rows", "2", "--cols", "3",
                "--mask-mode", "alpha", "--padding", "2",
                "--repack-dir", str(root / "repacked"),
                "--manifest", str(manifest_path),
            ]
            if empty_slots:
                arguments.extend(["--empty-slots", *(str(slot) for slot in empty_slots)])
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(main(arguments), 0)
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(len(list(output_dir.glob("*.png"))), manifest["count"])
            for record in manifest["sprites"]:
                self.assertTrue(Path(record["file"]).is_file())
            if empty_slots == (6,) and 6 not in occupied_slots:
                with Image.open(root / "repacked" / "sheet-0_repacked.png") as repacked:
                    last_cell = repacked.crop((
                        repacked.width * 2 // 3, repacked.height // 2,
                        repacked.width, repacked.height,
                    ))
                    self.assertIsNone(last_cell.getchannel("A").getbbox())
            return manifest

    def test_declared_last_slot_yields_25_frames_without_warnings(self) -> None:
        manifest = self.run_sheet_case((1, 2, 3, 4, 5), empty_slots=(6,), sheet_count=5)
        self.assertEqual(manifest["count"], 25)
        self.assertEqual(manifest["expected_count"], 25)
        self.assertEqual(manifest["declared_empty_slots"], [6])
        self.assertEqual(manifest["warnings"], [])
        self.assertEqual([record["source_slot"] for record in manifest["sprites"]], [1, 2, 3, 4, 5] * 5)

    def test_missing_required_slot_remains_a_warning(self) -> None:
        manifest = self.run_sheet_case((1, 2, 3, 4), empty_slots=(6,))
        self.assertEqual(manifest["expected_count"], 5)
        self.assertIn("expected occupied slots are empty: [5]", manifest["warnings"][0])

    def test_foreground_in_declared_empty_slot_is_warned_and_preserved(self) -> None:
        manifest = self.run_sheet_case((1, 2, 3, 4, 5, 6), empty_slots=(6,))
        self.assertEqual(manifest["count"], 6)
        self.assertIn("declared empty slots contain foreground: [6]", manifest["warnings"][0])
        self.assertIn(6, [record["source_slot"] for record in manifest["sprites"]])

    def test_equal_count_cannot_hide_missing_and_unexpected_slots(self) -> None:
        manifest = self.run_sheet_case((1, 2, 3, 4, 6), empty_slots=(6,))
        self.assertEqual(manifest["count"], manifest["expected_count"])
        self.assertEqual(len(manifest["warnings"]), 2)
        self.assertIn("expected occupied slots are empty: [5]", manifest["warnings"][0])
        self.assertIn("declared empty slots contain foreground: [6]", manifest["warnings"][1])

    def test_legacy_full_grid_still_passes_and_undeclared_gap_still_warns(self) -> None:
        full = self.run_sheet_case((1, 2, 3, 4, 5, 6))
        self.assertEqual(full["expected_count"], 6)
        self.assertEqual(full["declared_empty_slots"], [])
        self.assertEqual(full["warnings"], [])
        partial = self.run_sheet_case((1, 2, 3, 4, 5))
        self.assertEqual(partial["warnings"], ["sheet-0.png: detected 5/6 occupied slots"])

    def test_invalid_empty_slots_fail_before_output_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            input_dir = root / "originals"
            output_dir = root / "split"
            input_dir.mkdir()
            output_dir.mkdir()
            sentinel = output_dir / "keep.txt"
            sentinel.write_text("keep", encoding="utf-8")
            for values in (("6", "6"), ("0",), ("7",), ("-1",)):
                with self.subTest(values=values):
                    with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                        main([
                            str(input_dir), str(output_dir),
                            "--rows", "2", "--cols", "3", "--clean-output",
                            "--empty-slots", *values,
                        ])
                    self.assertEqual(error.exception.code, 2)
                    self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")


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
