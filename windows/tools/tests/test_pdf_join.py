"""Run with: python -m unittest discover -s windows/tools/tests -p test_pdf_join.py"""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

from pypdf import PdfReader, PdfWriter
from pypdf.generic import (ArrayObject, DictionaryObject, FloatObject,
                          NameObject, NumberObject, TextStringObject)


BACKEND = Path(__file__).resolve().parents[1] / "pdf_join.py"
spec = importlib.util.spec_from_file_location("pdf_join", BACKEND)
pdf_join = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pdf_join)


class PdfJoinTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pdf-join-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def pdf(self, name, widths=(200,), password=None, form=False, outline=None):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        writer = PdfWriter()
        for width in widths:
            writer.add_blank_page(width=width, height=300)
        if outline:
            writer.add_outline_item(outline, 0)
        if form:
            field = DictionaryObject({
                NameObject("/FT"): NameObject("/Tx"),
                NameObject("/T"): TextStringObject("name"),
                NameObject("/V"): TextStringObject(name),
                NameObject("/Type"): NameObject("/Annot"),
                NameObject("/Subtype"): NameObject("/Widget"),
                NameObject("/Rect"): ArrayObject([FloatObject(n) for n in (20, 20, 100, 40)]),
                NameObject("/F"): NumberObject(4),
            })
            reference = writer._add_object(field)
            writer.pages[0][NameObject("/Annots")] = ArrayObject([reference])
            writer._root_object[NameObject("/AcroForm")] = writer._add_object(DictionaryObject({
                NameObject("/Fields"): ArrayObject([reference]),
            }))
        if password:
            writer.encrypt(password)
        with path.open("wb") as target:
            writer.write(target)
        writer.close()
        return path

    def merge(self, paths, output="joined.pdf"):
        return pdf_join.handle({"action": "merge", "paths": [str(p) for p in paths],
                                "output": str(self.root / output)})

    def scan(self, recursive=False, exclude=None):
        return pdf_join.handle({"action": "scan", "folder": str(self.root),
                                "recursive": recursive,
                                "exclude": [str(p) for p in (exclude or [])]})

    def test_natural_case_insensitive_scan_and_recursion(self):
        for name in ("10.pdf", "2.PDF", "1.pdf", "folder/3.PdF", "folder/12.pdf"):
            self.pdf(name)
        (self.root / "ignore.txt").write_text("not PDF")
        self.assertEqual([p["relative"] for p in self.scan()["files"]], ["1.pdf", "2.PDF", "10.pdf"])
        excluded = self.root / "folder" / "12.pdf"
        result = self.scan(recursive=True, exclude=[excluded])
        self.assertEqual([p["relative"].replace("\\", "/") for p in result["files"]],
                         ["1.pdf", "2.PDF", "10.pdf", "folder/3.PdF"])
        self.assertTrue(all(Path(p["path"]).is_absolute() and p["size"] > 0 for p in result["files"]))

    def test_scan_works_without_site_packages_and_accepts_unicode_brackets(self):
        self.pdf("\u00c1rv\u00edzt\u0171r\u0151 [1] \u6d4b\u8bd5.PDF")
        request = {"action": "scan", "folder": str(self.root), "recursive": True}
        run = subprocess.run([sys.executable, "-S", str(BACKEND)],
                             input=json.dumps(request).encode("utf-8"), capture_output=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        response = json.loads(run.stdout)
        self.assertTrue(response["ok"])
        self.assertEqual(len(response["files"]), 1)
        self.assertIn("[1]", response["files"][0]["path"])

    def test_scan_warns_when_subfolder_cannot_be_read(self):
        folder = self.root / "unreadable"
        folder.mkdir()
        real_scandir = os.scandir

        def guarded(path):
            if Path(path) == folder:
                raise PermissionError("test denied access")
            return real_scandir(path)

        with mock.patch.object(pdf_join.os, "scandir", side_effect=guarded):
            result = self.scan(recursive=True)
        self.assertEqual(result["files"], [])
        self.assertEqual(len(result["warnings"]), 1)
        self.assertIn("unreadable", result["warnings"][0])

    def test_scan_does_not_recurse_through_links(self):
        self.pdf("actual/1.pdf")
        link = self.root / "actual" / "loop"
        try:
            link.symlink_to(self.root, target_is_directory=True)
        except OSError:
            self.skipTest("Directory symlinks unavailable for this Windows account")
        result = self.scan(recursive=True)
        self.assertEqual(len(result["files"]), 1)

    def test_scan_skips_junction_tags_but_traverses_cloud_directories(self):
        folder_entry = mock.Mock()
        folder_entry.name = "linked"
        folder_entry.path = str(self.root / "linked")
        folder_entry.stat.return_value = SimpleNamespace(st_file_attributes=0x400, st_reparse_tag=0xA0000003)
        folder_entry.is_symlink.return_value = False
        folder_entry.is_dir.return_value = True
        cloud_entry = mock.Mock()
        cloud_entry.name = "cloud"
        cloud_entry.path = str(self.root / "cloud")
        cloud_entry.stat.return_value = SimpleNamespace(st_file_attributes=0x400, st_reparse_tag=0x9000001A)
        cloud_entry.is_symlink.return_value = False
        cloud_entry.is_dir.return_value = True
        file_entry = mock.Mock()
        file_entry.name = "cloud.pdf"
        file_entry.path = str(self.root / "cloud" / "cloud.pdf")
        file_entry.stat.return_value = SimpleNamespace(st_file_attributes=0x400, st_reparse_tag=0x9000001A, st_mode=0o100644, st_size=123)
        file_entry.is_symlink.return_value = False
        file_entry.is_dir.return_value = False
        entries = mock.MagicMock()
        entries.__enter__.return_value = [folder_entry, cloud_entry]
        cloud_files = mock.MagicMock()
        cloud_files.__enter__.return_value = [file_entry]
        for tag in (0xA0000003, 0xA000000C):
            with self.subTest(tag=hex(tag)):
                folder_entry.stat.return_value.st_reparse_tag = tag
                with mock.patch.object(pdf_join.os, "scandir", side_effect=[entries, cloud_files]) as scandir:
                    result = self.scan(recursive=True)
                self.assertEqual(scandir.call_args_list, [mock.call(self.root), mock.call(self.root / "cloud")])
                self.assertEqual([item["relative"].replace("\\", "/") for item in result["files"]], ["cloud/cloud.pdf"])
                self.assertEqual(len(result["warnings"]), 1)
                self.assertIn("Skipped linked folder", result["warnings"][0])

    def test_more_than_ten_inputs_keep_explicit_order_and_all_pages(self):
        paths = [self.pdf("{}.pdf".format(i), widths=(100 + i, 200 + i)) for i in range(1, 13)]
        result = self.merge(list(reversed(paths)))
        self.assertEqual((result["files"], result["pages"]), (12, 24))
        reader = PdfReader(result["output"])
        expected = [width for i in range(12, 0, -1) for width in (100 + i, 200 + i)]
        self.assertEqual([int(page.mediabox.width) for page in reader.pages], expected)

    def test_forms_with_same_names_are_independent_and_outlines_survive(self):
        a = self.pdf("a.pdf", form=True, outline="First")
        b = self.pdf("b.pdf", form=True, outline="Second")
        result = self.merge([a, b])
        reader = PdfReader(result["output"])
        fields = reader.get_fields()
        self.assertEqual(fields["pdf_1.name"]["/V"], "a.pdf")
        self.assertEqual(fields["pdf_2.name"]["/V"], "b.pdf")
        self.assertEqual([entry.title for entry in reader.outline], ["First", "Second"])

    def test_unicode_and_brackets_merge(self):
        source = self.pdf("\u00e1 [draft]/r\u00e9sum\u00e9.PDF")
        result = self.merge([source], "\u00f6sszef\u0171z\u00f6tt [2].pdf")
        self.assertEqual(len(PdfReader(result["output"]).pages), 1)

    def test_invalid_later_input_creates_no_partial_output(self):
        good = self.pdf("good.pdf")
        bad = self.root / "broken.pdf"
        bad.write_bytes(b"not a PDF")
        with self.assertRaisesRegex(pdf_join.JoinError, "Cannot read PDF"):
            self.merge([good, bad])
        self.assertFalse((self.root / "joined.pdf").exists())
        self.assertEqual(list(self.root.glob(".pdf-join-*")), [])

    def test_encrypted_and_empty_inputs_fail_whole_job(self):
        good = self.pdf("good.pdf")
        encrypted = self.pdf("encrypted.pdf", password="secret")
        empty = self.pdf("empty.pdf", widths=())
        for invalid, message in ((encrypted, "Password-protected"), (empty, "no pages")):
            with self.subTest(invalid=invalid.name):
                with self.assertRaisesRegex(pdf_join.JoinError, message):
                    self.merge([good, invalid])
                self.assertFalse((self.root / "joined.pdf").exists())

    def test_existing_output_and_input_are_preserved(self):
        source = self.pdf("source.pdf")
        original = source.read_bytes()
        with self.assertRaisesRegex(pdf_join.JoinError, "already exists"):
            self.merge([source], "source.pdf")
        existing = self.pdf("joined.pdf", widths=(999,))
        existing_bytes = existing.read_bytes()
        with self.assertRaisesRegex(pdf_join.JoinError, "already exists"):
            self.merge([source])
        self.assertEqual(source.read_bytes(), original)
        self.assertEqual(existing.read_bytes(), existing_bytes)

    def test_duplicate_inputs_and_hardlink_alias_are_rejected(self):
        source = self.pdf("source.pdf")
        with self.assertRaisesRegex(pdf_join.JoinError, "more than once"):
            self.merge([source, source])
        alias = self.root / "alias.pdf"
        try:
            os.link(source, alias)
        except OSError:
            self.skipTest("Hard links unavailable")
        with self.assertRaisesRegex(pdf_join.JoinError, "more than once"):
            self.merge([source, alias])
        with self.assertRaisesRegex(pdf_join.JoinError, "already exists"):
            self.merge([source], "alias.pdf")

    def test_failed_write_cleans_temp_file(self):
        source = self.pdf("source.pdf")
        with mock.patch.object(PdfWriter, "write", side_effect=OSError("disk full")):
            with self.assertRaisesRegex(pdf_join.JoinError, "disk full"):
                self.merge([source])
        self.assertFalse((self.root / "joined.pdf").exists())
        self.assertEqual(list(self.root.glob(".pdf-join-*")), [])

    def test_incomplete_output_is_rejected_before_commit(self):
        source = self.pdf("source.pdf", widths=(100, 200))
        original_write = PdfWriter.write

        def incomplete_write(writer, target):
            replacement = PdfWriter()
            replacement.add_blank_page(width=100, height=200)
            result = original_write(replacement, target)
            replacement.close()
            return result

        with mock.patch.object(PdfWriter, "write", incomplete_write):
            with self.assertRaisesRegex(pdf_join.JoinError, "expected 2 pages, found 1"):
                self.merge([source])
        self.assertFalse((self.root / "joined.pdf").exists())
        self.assertEqual(list(self.root.glob(".pdf-join-*")), [])

    def test_destination_created_during_write_is_not_replaced(self):
        source = self.pdf("source.pdf")
        output = self.root / "joined.pdf"
        original_write = PdfWriter.write

        def racing_write(writer, target):
            result = original_write(writer, target)
            output.write_bytes(b"created by another process")
            return result

        with mock.patch.object(PdfWriter, "write", racing_write):
            with self.assertRaisesRegex(pdf_join.JoinError, "already exists"):
                self.merge([source])
        self.assertEqual(output.read_bytes(), b"created by another process")
        self.assertEqual(list(self.root.glob(".pdf-join-*")), [])

    def test_invalid_requests_return_single_json_error_and_failure_exit(self):
        for request in ([], {"action": "merge", "paths": []},
                        {"action": "scan", "folder": "relative"}, {"action": "unknown"}):
            run = subprocess.run([sys.executable, str(BACKEND)],
                                 input=json.dumps(request).encode("utf-8"), capture_output=True)
            self.assertNotEqual(run.returncode, 0)
            result = json.loads(run.stdout)
            self.assertFalse(result["ok"])
            self.assertTrue(result["error"])

    def test_output_extension_and_parent_validated(self):
        source = self.pdf("source.pdf")
        for output in ("joined.txt", "missing/joined.pdf"):
            with self.subTest(output=output):
                with self.assertRaises(pdf_join.JoinError):
                    self.merge([source], output)
                self.assertFalse((self.root / output).exists())

    def test_probe_reports_installed_version(self):
        result = pdf_join.handle({"action": "probe"})
        self.assertTrue(result["ok"])
        self.assertGreaterEqual(int(result["version"].split(".")[0]), 6)
        self.assertLess(int(result["version"].split(".")[0]), 7)

    def test_probe_rejects_unsupported_python_before_import(self):
        with mock.patch.object(pdf_join.sys, "version_info", (3, 9, 20)):
            with mock.patch.object(pdf_join.importlib, "import_module") as load_library:
                with self.assertRaisesRegex(pdf_join.JoinError, "Python 3.10"):
                    pdf_join.handle({"action": "probe"})
                load_library.assert_not_called()

    def test_probe_rejects_pypdf_outside_supported_major(self):
        for version in ("5.9.0", "7.0.0", "unknown"):
            with self.subTest(version=version):
                library = SimpleNamespace(__version__=version)
                with mock.patch.object(pdf_join.importlib, "import_module", return_value=library):
                    with self.assertRaisesRegex(pdf_join.JoinError, "pypdf >= 6, < 7"):
                        pdf_join.handle({"action": "probe"})


if __name__ == "__main__":
    unittest.main()
