#!/usr/bin/env python3
"""Small JSON bridge used by the PDF Joiner terminal interface.

Read one UTF-8 JSON request from stdin and emit one JSON response to stdout.
Scanning uses only the standard library; merging requires Python >= 3.10 and
pypdf >= 6, < 7.
"""

import contextlib
import importlib
import json
import logging
import os
from pathlib import Path
import re
import stat
import sys
import tempfile


class JoinError(Exception):
    """An actionable error suitable for displaying in the terminal."""


def absolute_path(value, label):
    if not isinstance(value, str) or not value.strip():
        raise JoinError("{} must be a nonempty absolute path.".format(label))
    if "\x00" in value or not os.path.isabs(value):
        raise JoinError("{} must be an absolute path.".format(label))
    return Path(os.path.abspath(value))


def path_key(path):
    return os.path.normcase(os.path.realpath(path))


def natural_key(value):
    # A final original-string tie breaker makes mixed case and leading zeros
    # deterministic even on case-sensitive filesystems.
    parts = re.split(r"(\d+)", value.casefold().replace("\\", "/"))
    return tuple((1, int(part)) if part.isdigit() else (0, part)
                 for part in parts), value


def scan(request):
    folder = absolute_path(request.get("folder"), "Folder")
    recursive = request.get("recursive", False)
    if not isinstance(recursive, bool):
        raise JoinError("Recursive must be true or false.")
    excluded = request.get("exclude", [])
    if not isinstance(excluded, list):
        raise JoinError("Exclude must be a list of absolute paths.")
    excluded_keys = {path_key(absolute_path(item, "Excluded file"))
                     for item in excluded}
    if not folder.is_dir():
        raise JoinError("Folder does not exist or is not a directory: {}".format(folder))

    files = []
    warnings = []
    pending = [folder]
    while pending:
        current = pending.pop()
        try:
            with os.scandir(current) as entries:
                for entry in entries:
                    try:
                        info = entry.stat(follow_symlinks=False)
                        # Both junctions and cloud placeholders have the reparse
                        # attribute. Check the actual tag, available on Windows
                        # since Python 3.8, so OneDrive folders remain browsable.
                        linked = entry.is_symlink() or getattr(info, "st_reparse_tag", 0) in (
                            getattr(stat, "IO_REPARSE_TAG_MOUNT_POINT", 0xA0000003),
                            getattr(stat, "IO_REPARSE_TAG_SYMLINK", 0xA000000C),
                        )
                        if entry.is_dir(follow_symlinks=False):
                            if recursive:
                                if linked:
                                    warnings.append("Skipped linked folder: {}".format(entry.path))
                                else:
                                    pending.append(Path(entry.path))
                            continue
                        # Cloud placeholders (for example OneDrive files) also
                        # carry a reparse attribute. Only actual file symlinks
                        # are excluded here; the directory guard above prevents
                        # junction traversal without hiding cloud-backed PDFs.
                        if entry.is_symlink() or not stat.S_ISREG(info.st_mode):
                            continue
                        if Path(entry.name).suffix.casefold() != ".pdf":
                            continue
                        if path_key(entry.path) in excluded_keys:
                            continue
                        files.append({
                            "path": os.path.abspath(entry.path),
                            "relative": os.path.relpath(entry.path, folder),
                            "size": info.st_size,
                        })
                    except OSError as exc:
                        warnings.append("Could not inspect {}: {}".format(entry.path, exc))
        except OSError as exc:
            warnings.append("Could not read folder {}: {}".format(current, exc))

    files.sort(key=lambda item: natural_key(item["relative"]))
    warnings.sort(key=natural_key)
    return {"ok": True, "folder": str(folder), "files": files, "warnings": warnings}


def pdf_library():
    if sys.version_info < (3, 10):
        raise JoinError("PDF joining requires Python 3.10 or newer. Install a supported Python version and pypdf >= 6, < 7.")
    try:
        library = importlib.import_module("pypdf")
    except ImportError as exc:
        raise JoinError("PDF joining requires pypdf >= 6, < 7. Install it with: python -m pip install \"pypdf>=6,<7\"") from exc
    version = getattr(library, "__version__", "unknown")
    match = re.match(r"(\d+)", version)
    if not match or int(match.group(1)) != 6:
        raise JoinError("pypdf >= 6, < 7 is required; found {}. Install a supported version with: python -m pip install --upgrade \"pypdf>=6,<7\"".format(version))
    return library


def merge(request):
    paths = request.get("paths")
    if not isinstance(paths, list) or not paths:
        raise JoinError("Select at least one PDF to join.")
    sources = [absolute_path(value, "Input file") for value in paths]
    output = absolute_path(request.get("output"), "Output file")
    if output.suffix.casefold() != ".pdf":
        raise JoinError("Output file must have a .pdf extension.")
    if not output.parent.is_dir():
        raise JoinError("Output folder does not exist: {}".format(output.parent))
    if os.path.lexists(output):
        raise JoinError("Output already exists. Choose another filename: {}".format(output))

    identities = set()
    normalized = set()
    output_key = path_key(output)
    for source in sources:
        if source.suffix.casefold() != ".pdf":
            raise JoinError("Input file must have a .pdf extension: {}".format(source))
        key = path_key(source)
        if key == output_key:
            raise JoinError("Output cannot replace an input file: {}".format(source))
        try:
            info = source.stat()
        except OSError as exc:
            raise JoinError("Cannot read input file {}: {}".format(source, exc)) from exc
        if not stat.S_ISREG(info.st_mode):
            raise JoinError("Input is not a regular file: {}".format(source))
        identity = (info.st_dev, info.st_ino) if info.st_ino else None
        if key in normalized or (identity is not None and identity in identities):
            raise JoinError("The same input PDF was selected more than once: {}".format(source))
        normalized.add(key)
        if identity is not None:
            identities.add(identity)

    library = pdf_library()
    temp_path = None
    pages = 0
    # Keep source streams open until serialization: pypdf reads some objects
    # lazily. No output file is made until all selected inputs have been read.
    try:
        with contextlib.ExitStack() as stack:
            readers = []
            for source in sources:
                try:
                    stream = stack.enter_context(source.open("rb"))
                    reader = library.PdfReader(stream)
                    if reader.is_encrypted:
                        raise JoinError("Password-protected PDF cannot be joined: {}. Save an unprotected copy first.".format(source))
                    count = len(reader.pages)
                    if count == 0:
                        raise JoinError("PDF has no pages: {}".format(source))
                    pages += count
                    readers.append(reader)
                except JoinError:
                    raise
                except Exception as exc:
                    raise JoinError("Cannot read PDF {}: {}".format(source, exc)) from exc

            writer = library.PdfWriter()
            stack.callback(writer.close)
            for index, reader in enumerate(readers, 1):
                try:
                    # Identical field names in different files must stay
                    # independent, rather than becoming one shared form field.
                    reader.add_form_topname("pdf_{}".format(index))
                    writer.append(reader, import_outline=True)
                except Exception as exc:
                    raise JoinError("Cannot join PDF {}: {}".format(sources[index - 1], exc)) from exc

            descriptor, temp_name = tempfile.mkstemp(
                prefix=".pdf-join-", suffix=".tmp", dir=str(output.parent))
            temp_path = Path(temp_name)
            with os.fdopen(descriptor, "wb") as target:
                writer.write(target)
                target.flush()
                os.fsync(target.fileno())

        # Reopen the serialized file before publishing it: a failed or
        # incomplete write must never be reported as a successful merge.
        try:
            with temp_path.open("rb") as verification:
                verified = library.PdfReader(verification, strict=True)
                actual_pages = len(verified.pages)
                if actual_pages != pages:
                    raise JoinError("Generated PDF verification failed: expected {} pages, found {}. Output was not saved.".format(pages, actual_pages))
        except JoinError:
            raise
        except Exception as exc:
            raise JoinError("Generated PDF verification failed. Output was not saved: {}".format(exc)) from exc

        # Windows rename is atomic and fails if the destination already exists.
        # POSIX rename replaces destinations, so use an atomic no-clobber link.
        if os.name == "nt":
            os.rename(temp_path, output)
        else:
            os.link(temp_path, output)
            temp_path.unlink()
        temp_path = None
        return {"ok": True, "output": str(output), "files": len(sources), "pages": pages}
    except JoinError:
        raise
    except FileExistsError as exc:
        raise JoinError("Output already exists. Choose another filename: {}".format(output)) from exc
    except Exception as exc:
        raise JoinError("Could not save joined PDF to {}: {}".format(output, exc)) from exc
    finally:
        if temp_path is not None:
            with contextlib.suppress(OSError):
                temp_path.unlink()


def handle(request):
    if not isinstance(request, dict):
        raise JoinError("Request must be a JSON object.")
    action = request.get("action")
    if action == "scan":
        return scan(request)
    if action == "merge":
        return merge(request)
    if action == "probe":
        return {"ok": True, "version": pdf_library().__version__}
    raise JoinError("Unknown action. Use scan, merge, or probe.")


def main():
    # pypdf diagnostics belong on stderr, never in the JSON protocol.
    logging.basicConfig(stream=sys.stderr, level=logging.ERROR)
    try:
        request = json.loads(sys.stdin.buffer.read().decode("utf-8-sig"))
        result = handle(request)
        code = 0
    except Exception as exc:
        result = {"ok": False, "error": str(exc) or type(exc).__name__}
        code = 1
    print(json.dumps(result, ensure_ascii=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
