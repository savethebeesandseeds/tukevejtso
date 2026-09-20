"""Functional compression tests; requires only the tool's pypdf and Pillow."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from PIL import Image

from pypdf import PdfReader, PdfWriter
from pypdf.generic import (ArrayObject, DecodedStreamObject, DictionaryObject,
                          NameObject, NumberObject, TextStringObject)

BACKEND = Path(__file__).resolve().parents[1] / "pdf_compress.py"
spec = importlib.util.spec_from_file_location("pdf_compress", BACKEND)
pdf_compress = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pdf_compress)


class CompressionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pdf-compress-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def fixture(self, name="input.pdf", alpha=False, signed=False, encrypted=False):
        writer = PdfWriter()
        page = writer.add_blank_page(width=400, height=500)
        writer.add_blank_page(width=300, height=200)
        writer.add_outline_item("Image and text", 0)
        writer.add_outline_item("Second page", 1)
        writer.add_metadata({"/Title": "Compression fixture"})
        writer.add_attachment("notes.txt", b"keep this attachment")
        image = DecodedStreamObject()
        noise = random.Random(73).randbytes(256 * 256 * 3)
        self.pixels = bytes(((index // 3) % 220) + value // 8
                            for index, value in enumerate(noise))
        image.set_data(self.pixels)
        image.update({NameObject("/Type"): NameObject("/XObject"),
                      NameObject("/Subtype"): NameObject("/Image"),
                      NameObject("/Width"): NumberObject(256),
                      NameObject("/Height"): NumberObject(256),
                      NameObject("/ColorSpace"): NameObject("/DeviceRGB"),
                      NameObject("/BitsPerComponent"): NumberObject(8)})
        if alpha:
            mask = DecodedStreamObject()
            mask.set_data(bytes(range(256)) * 256)
            mask.update({NameObject("/Type"): NameObject("/XObject"),
                         NameObject("/Subtype"): NameObject("/Image"),
                         NameObject("/Width"): NumberObject(256),
                         NameObject("/Height"): NumberObject(256),
                         NameObject("/ColorSpace"): NameObject("/DeviceGray"),
                         NameObject("/BitsPerComponent"): NumberObject(8)})
            image[NameObject("/SMask")] = writer._add_object(mask.flate_encode())
        font = DictionaryObject({NameObject("/Type"): NameObject("/Font"),
                                 NameObject("/Subtype"): NameObject("/Type1"),
                                 NameObject("/BaseFont"): NameObject("/Helvetica")})
        page[NameObject("/Resources")] = DictionaryObject({
            NameObject("/XObject"): DictionaryObject({NameObject("/Photo"): writer._add_object(image.flate_encode())}),
            NameObject("/Font"): DictionaryObject({NameObject("/F1"): writer._add_object(font)})})
        content = DecodedStreamObject()
        content.set_data(b"q 256 0 0 256 20 80 cm /Photo Do Q\nBT /F1 12 Tf 20 20 Td (Preserve selectable text) Tj ET\n" + b"% padding\n" * 100)
        page[NameObject("/Contents")] = writer._add_object(content)
        rect = ArrayObject([NumberObject(n) for n in (20, 20, 150, 40)])
        field = DictionaryObject({NameObject("/Type"): NameObject("/Annot"),
                                  NameObject("/Subtype"): NameObject("/Widget"),
                                  NameObject("/FT"): NameObject("/Sig" if signed else "/Tx"),
                                  NameObject("/T"): TextStringObject("test-field"),
                                  NameObject("/V"): TextStringObject("signed" if signed else "Keep this value"),
                                  NameObject("/Rect"): rect})
        field_ref = writer._add_object(field)
        writer._root_object[NameObject("/AcroForm")] = DictionaryObject({NameObject("/Fields"): ArrayObject([field_ref])})
        link = DictionaryObject({NameObject("/Type"): NameObject("/Annot"),
                                 NameObject("/Subtype"): NameObject("/Link"),
                                 NameObject("/Rect"): rect,
                                 NameObject("/A"): DictionaryObject({NameObject("/S"): NameObject("/URI"),
                                                                   NameObject("/URI"): TextStringObject("https://example.com/")})})
        page[NameObject("/Annots")] = ArrayObject([field_ref, writer._add_object(link)])
        if encrypted:
            writer.encrypt("secret")
        path = self.root / name
        writer.write(path)
        writer.close()
        return path

    def compress(self, source, **kwargs):
        return pdf_compress.handle({"action": "compress", "input": str(source), **kwargs})

    def test_balanced_reduces_size_and_preserves_document_features(self):
        source = self.fixture()
        before = source.read_bytes()
        result = self.compress(source)
        self.assertTrue(result["saved"])
        self.assertGreater(result["reduction_percent"], 30)
        self.assertEqual(source.read_bytes(), before)
        original, output = PdfReader(source), PdfReader(result["output"])
        self.assertEqual(len(output.pages), 2)
        self.assertEqual([p.extract_text() for p in output.pages], [p.extract_text() for p in original.pages])
        self.assertEqual(output.get_fields()["test-field"]["/V"], "Keep this value")
        self.assertEqual(output.pages[0]["/Annots"][1].get_object()["/A"]["/URI"], "https://example.com/")
        self.assertEqual([item.title for item in output.outline], ["Image and text", "Second page"])
        self.assertEqual(output.metadata.title, original.metadata.title)
        self.assertEqual(output.attachments["notes.txt"], [b"keep this attachment"])
        self.assertEqual(output.pages[0].images[0].image.size, (256, 256))

    def test_lossless_preserves_pixels_and_small_is_smaller(self):
        source = self.fixture()
        lossless = self.compress(source, preset="lossless")
        image = PdfReader(lossless["output"]).pages[0].images[0].image
        self.assertEqual(image.convert("RGB").tobytes(), self.pixels)
        balanced = self.compress(source, preset="balanced")
        small = self.compress(source, preset="small")
        self.assertLess(small["after_bytes"], balanced["after_bytes"])

    def test_soft_mask_pixels_and_dimensions_are_preserved(self):
        source = self.fixture(alpha=True)
        result = self.compress(source)
        output = PdfReader(result["output"]).pages[0].images[0].image
        self.assertEqual(output.mode, "RGBA")
        self.assertEqual(output.size, (256, 256))
        self.assertEqual(output.getchannel("A").tobytes(), bytes(range(256)) * 256)

    def test_collision_defaults_and_explicit_no_clobber(self):
        source = self.fixture("M\u0171hely [1] \u6771.pdf")
        first = self.compress(source)
        self.assertEqual(Path(first["output"]).name, source.stem + " - compressed.pdf")
        first_bytes = Path(first["output"]).read_bytes()
        second = self.compress(source)
        self.assertTrue(second["output"].endswith(" (2).pdf"))
        with self.assertRaisesRegex(pdf_compress.CompressionError, "already exists"):
            self.compress(source, output=first["output"])
        with self.assertRaisesRegex(pdf_compress.CompressionError, "replace the input"):
            self.compress(source, output=str(source))
        self.assertEqual(Path(first["output"]).read_bytes(), first_bytes)

    def test_encrypted_signed_and_invalid_inputs_leave_no_outputs(self):
        for options, message in (({"encrypted": True}, "Password-protected"), ({"signed": True}, "Digitally signed")):
            source = self.fixture(**options)
            with self.assertRaisesRegex(pdf_compress.CompressionError, message):
                self.compress(source)
        broken = self.root / "broken.pdf"
        broken.write_bytes(b"broken")
        with self.assertRaises(pdf_compress.CompressionError):
            self.compress(broken)
        with self.assertRaisesRegex(pdf_compress.CompressionError, "Preset"):
            self.compress(broken, preset="unknown")
        self.assertFalse(list(self.root.glob("*compressed*")))
        self.assertFalse(list(self.root.glob(".pdf-compress-*")))

    def test_custom_quality_resize_and_grayscale_preserve_text_and_alpha(self):
        source = self.fixture(alpha=True)
        result = self.compress(source, preset="custom", quality=72, max_dimension=128, grayscale=True)
        reader = PdfReader(result["output"])
        image = reader.pages[0].images[0].image
        self.assertEqual(image.size, (128, 128))
        rgb = image.convert("RGB")
        self.assertEqual(rgb.getchannel("R").tobytes(), rgb.getchannel("G").tobytes())
        self.assertEqual(rgb.getchannel("G").tobytes(), rgb.getchannel("B").tobytes())
        expected = PdfReader(source).pages[0].images[0].image.copy()
        expected.thumbnail((128, 128), Image.Resampling.LANCZOS)
        self.assertEqual(image.getchannel("A").tobytes(), expected.getchannel("A").tobytes())
        self.assertEqual(result["images_resized"], 1)
        self.assertEqual(result["images_grayscaled"], 1)
        self.assertEqual(reader.pages[0].extract_text(), PdfReader(source).pages[0].extract_text())

    def test_remove_metadata_clears_info_and_xmp_but_keeps_content(self):
        source = self.fixture()
        writer = PdfWriter(clone_from=source)
        metadata = DecodedStreamObject()
        metadata.set_data(b'<x:xmpmeta xmlns:x="adobe:ns:meta/">private properties</x:xmpmeta>')
        metadata.update({NameObject("/Type"): NameObject("/Metadata"), NameObject("/Subtype"): NameObject("/XML")})
        writer.root_object[NameObject("/Metadata")] = writer._add_object(metadata)
        annotated = self.root / "metadata.pdf"
        writer.write(annotated)
        result = self.compress(annotated, remove_metadata=True)
        reader = PdfReader(result["output"])
        self.assertFalse(reader.metadata)
        self.assertNotIn("/Metadata", reader.trailer["/Root"])
        self.assertEqual(reader.attachments["notes.txt"], [b"keep this attachment"])
        self.assertEqual(reader.get_fields()["test-field"]["/V"], "Keep this value")

    def test_explicit_overwrite_with_default_backup_and_backup_collision(self):
        source = self.fixture()
        original = source.read_bytes()
        prior_backup = self.root / "input - original.pdf"
        prior_backup.write_bytes(b"older backup")
        result = self.compress(source, overwrite=True)
        self.assertTrue(result["overwritten"])
        self.assertEqual(result["output"], str(source))
        self.assertLess(source.stat().st_size, len(original))
        self.assertEqual(Path(result["backup"]).name, "input - original (2).pdf")
        self.assertEqual(Path(result["backup"]).read_bytes(), original)
        self.assertEqual(prior_backup.read_bytes(), b"older backup")
        self.assertEqual(len(PdfReader(source).pages), 2)

    def test_overwrite_without_backup_and_conflicting_destination(self):
        source = self.fixture()
        with self.assertRaisesRegex(pdf_compress.CompressionError, "either overwrite"):
            self.compress(source, overwrite=True, output=str(self.root / "other.pdf"))
        result = self.compress(source, overwrite=True, keep_backup=False)
        self.assertTrue(result["overwritten"])
        self.assertIsNone(result["backup"])
        self.assertEqual(list(self.root.iterdir()), [source])

    def test_failed_replace_keeps_original_and_completed_backup(self):
        source = self.fixture()
        original = source.read_bytes()
        with mock.patch.object(pdf_compress.os, "replace", side_effect=PermissionError("file is open")):
            with self.assertRaisesRegex(pdf_compress.CompressionError, "Backup retained"):
                self.compress(source, overwrite=True)
        self.assertEqual(source.read_bytes(), original)
        self.assertEqual((self.root / "input - original.pdf").read_bytes(), original)
        self.assertFalse(list(self.root.glob(".pdf-compress-*")))

    def test_source_change_during_compression_prevents_overwrite(self):
        source = self.fixture()
        write = PdfWriter.write
        changed_bytes = source.read_bytes() + b"\n% changed by another application\n"

        def change_source(writer, destination):
            result = write(writer, destination)
            source.write_bytes(changed_bytes)
            return result

        with mock.patch.object(PdfWriter, "write", change_source):
            with self.assertRaisesRegex(pdf_compress.CompressionError, "changed during compression"):
                self.compress(source, overwrite=True)
        self.assertEqual(source.read_bytes(), changed_bytes)
        self.assertEqual(list(self.root.iterdir()), [source])

    def test_overwrite_no_reduction_creates_no_backup_and_leaves_original(self):
        writer = PdfWriter()
        writer.add_blank_page(width=200, height=300)
        source = self.root / "compact.pdf"
        writer.write(source)
        original = source.read_bytes()
        result = self.compress(source, preset="lossless", overwrite=True)
        self.assertFalse(result["saved"])
        self.assertFalse(result["overwritten"])
        self.assertIsNone(result["backup"])
        self.assertEqual(source.read_bytes(), original)
        self.assertEqual(list(self.root.iterdir()), [source])

    def test_settings_validation_and_inspection_do_not_write(self):
        source = self.fixture()
        result = pdf_compress.handle({"action": "inspect", "input": str(source)})
        self.assertEqual(result["pages"], 2)
        self.assertEqual(result["bytes"], source.stat().st_size)
        for settings in ({"quality": 19}, {"quality": True}, {"max_dimension": 64},
                         {"overwrite": "true"}, {"grayscale": 1}, {"keep_backup": 0},
                         {"preset": "lossless", "quality": 88}, {"preset": "lossless", "grayscale": True}):
            with self.subTest(settings=settings), self.assertRaises(pdf_compress.CompressionError):
                self.compress(source, **settings)
        self.assertEqual(list(self.root.iterdir()), [source])

    def test_no_savings_does_not_save_a_larger_copy(self):
        writer = PdfWriter()
        writer.add_blank_page(width=200, height=300)
        source = self.root / "compact.pdf"
        writer.write(source)
        result = self.compress(source, preset="lossless")
        self.assertFalse(result["saved"])
        self.assertIsNone(result["output"])
        self.assertEqual(result["saved_bytes"], 0)
        self.assertEqual(list(self.root.iterdir()), [source])

    def test_failed_write_cleans_temp_and_preserves_input(self):
        source = self.fixture()
        before = hashlib.sha256(source.read_bytes()).digest()
        with mock.patch.object(PdfWriter, "write", side_effect=OSError("disk full")):
            with self.assertRaisesRegex(pdf_compress.CompressionError, "disk full"):
                self.compress(source)
        self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), before)
        self.assertEqual(list(self.root.iterdir()), [source])

    def test_destination_created_during_run_is_not_replaced(self):
        source = self.fixture()
        output = self.root / "result.pdf"
        operation = "rename" if os.name == "nt" else "link"
        real_publish = getattr(pdf_compress.os, operation)

        def collision(temp, destination):
            output.write_bytes(b"another process saved this")
            return real_publish(temp, destination)

        with mock.patch.object(pdf_compress.os, operation, side_effect=collision):
            with self.assertRaisesRegex(pdf_compress.CompressionError, "already exists"):
                self.compress(source, output=str(output))
        self.assertEqual(output.read_bytes(), b"another process saved this")
        self.assertFalse(list(self.root.glob(".pdf-compress-*")))

    def test_json_bridge_reports_success_and_invalid_request(self):
        source = self.fixture()
        process = subprocess.run([sys.executable, str(BACKEND)], input=json.dumps({"action": "compress", "input": str(source)}), capture_output=True, text=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertTrue(json.loads(process.stdout)["saved"])
        process = subprocess.run([sys.executable, str(BACKEND)], input="[]", capture_output=True, text=True)
        self.assertEqual(process.returncode, 1)
        self.assertFalse(json.loads(process.stdout)["ok"])

    @unittest.skipUnless(os.name == "nt", "Windows launcher")
    def test_windows_cli_custom_settings_and_explicit_overwrite(self):
        launcher = BACKEND.parents[1] / "tk.cmd"
        env = dict(os.environ, TUKEVEJTSO_PDF_PYTHON=sys.executable)
        source = self.fixture("custom options.pdf", alpha=True)
        original = source.read_bytes()
        command = ["cmd.exe", "/d", "/c", str(launcher), "compress-pdf", str(source),
                   "-Quality", "72", "-MaxImageDimension", "128", "-Grayscale", "-RemoveMetadata",
                   "-OverwriteOriginal", "-Json"]
        run = subprocess.run(command, capture_output=True, env=env)
        self.assertEqual(run.returncode, 0, (run.stdout, run.stderr))
        result = json.loads(run.stdout.decode("utf-8-sig"))
        self.assertTrue(result["overwritten"])
        self.assertEqual(Path(result["backup"]).read_bytes(), original)
        self.assertEqual(result["settings"]["quality"], 72)
        self.assertEqual(result["settings"]["max_dimension"], 128)
        self.assertTrue(result["settings"]["grayscale"])
        reader = PdfReader(source)
        self.assertFalse(reader.metadata)
        self.assertEqual(reader.pages[0].images[0].image.size, (128, 128))

    @unittest.skipUnless(os.name == "nt", "Windows launcher")
    def test_windows_command_aliases_unicode_paths_and_failure_exit_code(self):
        launcher = BACKEND.parents[1] / "tk.cmd"
        env = dict(os.environ, TUKEVEJTSO_PDF_PYTHON=sys.executable)
        for alias in ("compress-pdf", "pdf-compress", "shrink-pdf"):
            run = subprocess.run(["cmd.exe", "/d", "/c", str(launcher), alias, "-Help"],
                                 capture_output=True, env=env)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn(b"tk compress-pdf [PDF]", run.stdout)
        source = self.fixture("M\u0171hely [1] \u6771.pdf")
        run = subprocess.run(["cmd.exe", "/d", "/c", str(launcher), "compress-pdf", str(source), "-Json"],
                             capture_output=True, env=env)
        self.assertEqual(run.returncode, 0, run.stderr)
        result = json.loads(run.stdout.decode("utf-8-sig"))
        self.assertEqual(result["input"], str(source))
        self.assertTrue(Path(result["output"]).is_file())
        for args in ([str(self.root / "missing.pdf"), "-Json"], ["-Json"]):
            run = subprocess.run(["cmd.exe", "/d", "/c", str(launcher), "compress-pdf"] + args,
                                 capture_output=True, env=env)
            self.assertEqual(run.returncode, 1, (run.stdout, run.stderr))
            self.assertFalse(json.loads(run.stdout.decode("utf-8-sig"))["ok"])


if __name__ == "__main__":
    unittest.main()
