#!/usr/bin/env python3
"""Local PDF compression with explicit, verified replacement of originals."""

import contextlib
import hashlib
import importlib
from io import BytesIO
import json
import logging
import os
from pathlib import Path
import shutil
import sys
import tempfile


class CompressionError(Exception):
    """An actionable error for the terminal interface."""


PRESETS = {"lossless": (None, 0), "highquality": (95, 0),
           "balanced": (88, 0), "small": (65, 1600), "custom": (88, 0)}


def options(request):
    preset = request.get("preset", "balanced")
    if not isinstance(preset, str) or preset not in PRESETS:
        raise CompressionError("Preset must be lossless, highquality, balanced, small, or custom.")
    quality, dimension = PRESETS[preset]
    quality = request.get("quality", quality)
    dimension = request.get("max_dimension", dimension)
    if quality is not None and (type(quality) is not int or not 20 <= quality <= 95):
        raise CompressionError("Image quality must be an integer from 20 to 95.")
    if type(dimension) is not int or (dimension != 0 and not 128 <= dimension <= 10000):
        raise CompressionError("Maximum image dimension must be 0 (original) or 128 to 10000 pixels.")
    flags = {}
    for name, default in (("grayscale", False), ("remove_metadata", False),
                          ("overwrite", False), ("keep_backup", True)):
        value = request.get(name, default)
        if type(value) is not bool:
            raise CompressionError("{} must be true or false.".format(name))
        flags[name] = value
    if preset == "lossless" and (quality is not None or dimension or flags["grayscale"]):
        raise CompressionError("Lossless cannot change image quality, resolution, or color. Choose Custom instead.")
    if preset != "lossless" and quality is None:
        raise CompressionError("Image quality is required for this preset.")
    return dict(preset=preset, quality=quality, max_dimension=dimension, **flags)


def libraries():
    if sys.version_info < (3, 10):
        raise CompressionError("PDF compression requires Python 3.10 or newer.")
    try:
        pdf = importlib.import_module("pypdf")
        pillow = importlib.import_module("PIL.Image")
    except ImportError as exc:
        raise CompressionError('Install dependencies with: py -m pip install "pypdf>=6,<7" Pillow') from exc
    if pdf.__version__.split(".")[0] != "6":
        raise CompressionError('pypdf 6 is required. Run: py -m pip install "pypdf>=6,<7" Pillow')
    return pdf, pillow


def absolute_path(value, label):
    if not isinstance(value, str) or not value.strip() or "\x00" in value or not os.path.isabs(value):
        raise CompressionError("{} must be an absolute file path.".format(label))
    path = Path(os.path.abspath(value))
    if path.suffix.lower() != ".pdf":
        raise CompressionError("{} must have a .pdf extension.".format(label))
    return path


def available_output(source, suffix):
    stem = source.stem + suffix
    output = source.with_name(stem + ".pdf")
    number = 2
    while os.path.lexists(output):
        output = source.with_name("{} ({}).pdf".format(stem, number))
        number += 1
    return output


def default_output(source):
    return available_output(source, " - compressed")


def inspect_pdf(request):
    source = absolute_path(request.get("input"), "Input")
    pdf, _ = libraries()
    with source.open("rb") as stream:
        reader = pdf.PdfReader(stream)
        check_reader(reader)
        return {"ok": True, "input": str(source), "bytes": os.fstat(stream.fileno()).st_size,
                "pages": len(reader.pages), "output": str(default_output(source))}


def check_reader(reader):
    if reader.is_encrypted:
        raise CompressionError("Password-protected PDF: save an unprotected copy before compressing.")
    if not reader.pages:
        raise CompressionError("PDF has no pages.")
    if (reader.trailer["/Root"].get("/Perms")
            or any(field.get("/FT") == "/Sig" and field.get("/V")
                   for field in (reader.get_fields() or {}).values())):
        raise CompressionError("Digitally signed PDF: compression would invalidate its signature. Use an unsigned copy.")


def fingerprint(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


def digest_stream(stream):
    position = stream.tell()
    stream.seek(0)
    digest = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
    stream.seek(position)
    return digest.digest()


def check_unchanged(source, expected_info, expected_digest):
    if source.is_symlink():
        raise CompressionError("Cannot overwrite a symbolic link. Save a separate copy instead.")
    with source.open("rb") as stream:
        before = fingerprint(os.fstat(stream.fileno()))
        digest = digest_stream(stream)
        after = fingerprint(os.fstat(stream.fileno()))
    if before != expected_info or after != expected_info or digest != expected_digest:
        raise CompressionError("The original PDF changed during compression. It was not overwritten; run again.")


def replace_original(temp_path, source, expected_info, expected_digest, keep_backup):
    check_unchanged(source, expected_info, expected_digest)
    backup = None
    if keep_backup:
        # Reserve exclusively so even a concurrent save cannot clobber a backup.
        while True:
            candidate = available_output(source, " - original")
            try:
                target = candidate.open("xb")
                break
            except FileExistsError:
                continue
        try:
            with target, source.open("rb") as original:
                shutil.copyfileobj(original, target, 1024 * 1024)
                target.flush()
                os.fsync(target.fileno())
            with candidate.open("rb") as saved:
                if digest_stream(saved) != expected_digest:
                    raise CompressionError("The original changed while creating its backup. It was not overwritten.")
            backup = candidate
        except Exception:
            candidate.unlink(missing_ok=True)
            raise
    try:
        check_unchanged(source, expected_info, expected_digest)
        os.replace(temp_path, source)
    except Exception as exc:
        message = "Original was not replaced: {}".format(exc)
        if backup:
            message += " Backup retained at: {}".format(backup)
        raise CompressionError(message) from exc
    return str(backup) if backup else None


def snapshot(reader):
    """Check page painting instructions, navigation and form values after writing."""
    pages = []
    for page in reader.pages:
        content = page.get_contents()
        annotations = []
        for ref in page.get("/Annots", []):
            annotation = ref.get_object()
            action = annotation.get("/A")
            action = action.get_object() if action else {}
            annotations.append((str(annotation.get("/Subtype")),
                                str(annotation.get("/Rect")), str(action.get("/URI"))))
        pages.append((tuple(page.mediabox), tuple(page.cropbox), page.rotation,
                      hashlib.sha256(content.get_data() if content is not None else b"").hexdigest(),
                      annotations))

    def outlines(items):
        result = []
        for item in items:
            if isinstance(item, list):
                result.append(outlines(item))
            else:
                result.append((item.title, reader.get_destination_page_number(item)))
        return result

    fields = {name: (str(field.get("/FT")), str(field.get("/V")))
              for name, field in (reader.get_fields() or {}).items()}
    return pages, outlines(reader.outline), fields, sorted(reader.attachments)


def compress_images(writer, settings):
    """Re-encode supported raster images and keep soft masks aligned.

    Color-key masks, custom decode arrays, indexed/ICC/CMYK color spaces,
    inline images, and tiny icons are left alone. Only smaller documents are saved.
    pypdf 6's encoded stream storage is used so transparency remains separate.
    """
    from pypdf.generic import DecodedStreamObject, NameObject, NumberObject
    from PIL import Image

    changed = 0
    skipped = 0
    resized = 0
    grayscaled = 0
    seen = set()
    for page in writer.pages:
        for key in page.images.keys():
            try:
                image = page.images[key]
                if image.indirect_reference is None:
                    skipped += 1
                    continue
                identity = image.indirect_reference.idnum
                if identity in seen:
                    continue
                seen.add(identity)
                obj = image.indirect_reference.get_object()
                if (obj.get("/ColorSpace") not in ("/DeviceRGB", "/DeviceGray")
                        or obj.get("/BitsPerComponent") != 8
                        or any(name in obj for name in ("/Decode", "/Mask", "/SMaskInData"))
                        or obj.get("/ImageMask")
                        or image.image.mode not in ("RGB", "RGBA", "L", "LA")
                        or min(image.image.size) < 64 or len(obj._data) < 8192):
                    continue
                soft_mask = obj.get("/SMask")
                if soft_mask and soft_mask.get_object().get("/Matte"):
                    skipped += 1
                    continue
                mode = "L" if settings["grayscale"] or obj.get("/ColorSpace") == "/DeviceGray" else "RGB"
                original_image = image.image
                pixels = original_image.copy()
                maximum = settings["max_dimension"]
                if maximum and max(pixels.size) > maximum:
                    pixels.thumbnail((maximum, maximum), Image.Resampling.LANCZOS)
                did_resize = pixels.size != original_image.size
                did_grayscale = mode == "L" and obj.get("/ColorSpace") == "/DeviceRGB"
                buffer = BytesIO()
                pixels.convert(mode).save(buffer, format="JPEG", quality=settings["quality"],
                                              subsampling=0, optimize=True)
                encoded = buffer.getvalue()
                if len(encoded) >= len(obj._data) and not (did_resize or did_grayscale):
                    continue
                new_mask = None
                if did_resize and soft_mask:
                    new_mask = DecodedStreamObject()
                    new_mask.set_data(pixels.getchannel("A").tobytes())
                    new_mask.update({NameObject("/Type"): NameObject("/XObject"),
                                     NameObject("/Subtype"): NameObject("/Image"),
                                     NameObject("/Width"): NumberObject(pixels.width),
                                     NameObject("/Height"): NumberObject(pixels.height),
                                     NameObject("/ColorSpace"): NameObject("/DeviceGray"),
                                     NameObject("/BitsPerComponent"): NumberObject(8)})
            except Exception:
                # An unsupported image must not prevent structural compression.
                skipped += 1
                continue
            obj._data = encoded
            obj[NameObject("/Filter")] = NameObject("/DCTDecode")
            obj[NameObject("/BitsPerComponent")] = NumberObject(8)
            obj[NameObject("/ColorSpace")] = NameObject("/DeviceGray" if mode == "L" else "/DeviceRGB")
            obj[NameObject("/Width")] = NumberObject(pixels.width)
            obj[NameObject("/Height")] = NumberObject(pixels.height)
            if new_mask is not None:
                # Use a new mask object: the old mask may be shared by another image.
                obj[NameObject("/SMask")] = writer._add_object(new_mask.flate_encode())
            obj.pop(NameObject("/DecodeParms"), None)
            obj.decoded_self = None
            changed += 1
            resized += int(did_resize)
            grayscaled += int(did_grayscale)
    return changed, skipped, resized, grayscaled


def compress(request):
    source = absolute_path(request.get("input"), "Input")
    settings = options(request)
    if not source.is_file():
        raise CompressionError("Input PDF does not exist: {}".format(source))
    if settings["overwrite"] and request.get("output"):
        raise CompressionError("Choose either overwrite original or an output filename, not both.")
    output = (source if settings["overwrite"] else
              absolute_path(request["output"], "Output") if request.get("output")
              else default_output(source))
    if not settings["overwrite"] and os.path.normcase(os.path.realpath(source)) == os.path.normcase(os.path.realpath(output)):
        raise CompressionError("Output cannot replace the input PDF without the explicit overwrite option.")
    if settings["overwrite"] and source.is_symlink():
        raise CompressionError("Cannot overwrite a symbolic link. Save a separate copy instead.")
    if not settings["overwrite"] and os.path.lexists(output):
        raise CompressionError("Output already exists. Choose another filename: {}".format(output))
    if not output.parent.is_dir():
        raise CompressionError("Output folder does not exist: {}".format(output.parent))

    pdf, _ = libraries()
    temp_path = None
    try:
        with source.open("rb") as stream, contextlib.ExitStack() as stack:
            reader = pdf.PdfReader(stream)
            check_reader(reader)
            before = os.fstat(stream.fileno()).st_size
            source_info = fingerprint(os.fstat(stream.fileno()))
            source_digest = digest_stream(stream) if settings["overwrite"] else None
            original = snapshot(reader)
            writer = pdf.PdfWriter(clone_from=reader)
            stack.callback(writer.close)
            changed, skipped, resized, grayscaled = (0, 0, 0, 0)
            if settings["quality"] is not None:
                changed, skipped, resized, grayscaled = compress_images(writer, settings)
            if settings["remove_metadata"]:
                from pypdf.generic import NameObject
                writer.metadata = None
                writer.root_object.pop(NameObject("/Metadata"), None)
            for page in writer.pages:
                page.compress_content_streams(level=9)
            # Defaults remove duplicate and unreferenced objects in pypdf 6.x.
            writer.compress_identical_objects()
            descriptor, filename = tempfile.mkstemp(prefix=".pdf-compress-", suffix=".tmp",
                                                     dir=str(output.parent))
            temp_path = Path(filename)
            with os.fdopen(descriptor, "wb") as target:
                writer.write(target)
                target.flush()
                os.fsync(target.fileno())
            with temp_path.open("rb") as verification:
                checked = pdf.PdfReader(verification, strict=True)
                if snapshot(checked) != original:
                    raise CompressionError("PDF verification failed. No output was saved.")
            after = temp_path.stat().st_size
            result = {"ok": True, "saved": after < before, "input": str(source),
                      "output": None, "preset": settings["preset"], "settings": settings,
                      "overwritten": False, "backup": None, "pages": len(reader.pages),
                      "before_bytes": before, "after_bytes": min(before, after),
                      "saved_bytes": max(0, before - after),
                      "reduction_percent": round(max(0, 100 * (1 - after / before)), 1),
                      "images_compressed": changed, "images_skipped": skipped,
                      "images_resized": resized, "images_grayscaled": grayscaled}
            if after >= before:
                result["message"] = "No size reduction with this preset. The original is already compact; no copy was saved."
                return result

        # Replace only in explicit overwrite mode; new copies never clobber files.
        if settings["overwrite"]:
            result["backup"] = replace_original(temp_path, source, source_info, source_digest,
                                                  settings["keep_backup"])
            result["overwritten"] = True
        elif os.name == "nt":
            os.rename(temp_path, output)
        else:
            os.link(temp_path, output)
            temp_path.unlink()
        temp_path = None
        result["output"] = str(output)
        return result
    except CompressionError:
        raise
    except FileExistsError as exc:
        raise CompressionError("Output already exists. Choose another filename: {}".format(output)) from exc
    except Exception as exc:
        raise CompressionError("Could not compress PDF: {}".format(exc)) from exc
    finally:
        if temp_path is not None:
            with contextlib.suppress(OSError):
                temp_path.unlink()


def handle(request):
    if not isinstance(request, dict):
        raise CompressionError("Request must be a JSON object.")
    if request.get("action") == "probe":
        pdf, pillow = libraries()
        return {"ok": True, "version": pdf.__version__, "pillow": pillow.__version__}
    if request.get("action") == "compress":
        return compress(request)
    if request.get("action") == "inspect":
        return inspect_pdf(request)
    raise CompressionError("Unknown action. Use probe, inspect, or compress.")


def main():
    logging.basicConfig(stream=sys.stderr, level=logging.ERROR)
    try:
        result = handle(json.loads(sys.stdin.buffer.read().decode("utf-8-sig")))
        code = 0
    except Exception as exc:
        result = {"ok": False, "error": str(exc) or type(exc).__name__}
        code = 1
    print(json.dumps(result, ensure_ascii=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
