from __future__ import annotations

import importlib.util
import shutil
import sys
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class DependencyStatus:
    name: str
    available: bool
    detail: str


def module_available(name: str) -> bool:
    return importlib.util.find_spec(name) is not None


def command_available(name: str) -> bool:
    return shutil.which(name) is not None


def collect_status() -> list[DependencyStatus]:
    modules = [
        ("PIL", "Pillow image IO and previews"),
        ("numpy", "classic fallback and postprocessing"),
        ("torch", "PyTorch model providers"),
        ("torchvision", "BiRefNet preprocessing"),
        ("transformers", "Hugging Face model loading"),
        ("PySide6", "desktop GUI"),
    ]
    commands = [
        ("magick", "ImageMagick compatibility workflows"),
        ("ffmpeg", "GIF/frame helpers"),
        ("ffprobe", "metadata helpers"),
    ]

    statuses = [
        DependencyStatus("python", True, sys.version.split()[0]),
    ]
    statuses.extend(
        DependencyStatus(name, module_available(name), detail)
        for name, detail in modules
    )
    statuses.extend(
        DependencyStatus(name, command_available(name), detail)
        for name, detail in commands
    )
    return statuses
