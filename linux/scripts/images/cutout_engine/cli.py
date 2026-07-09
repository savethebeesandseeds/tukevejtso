from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

from . import __version__
from .dependencies import collect_status
from .errors import CutoutError
from .image_io import default_output_path
from .pipeline import run_cutout
from .postprocess import save_previews
from .providers import MODEL_INFOS
from .types import CutoutOptions


def add_engine_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--engine",
        choices=("auto", "classic", "birefnet"),
        default="auto",
        help="auto tries BiRefNet and falls back to classic if ML deps are absent",
    )
    parser.add_argument(
        "--preset",
        choices=("fast", "balanced", "pro"),
        default="balanced",
        help="quality/runtime preset",
    )
    parser.add_argument(
        "--device",
        choices=("auto", "cpu", "cuda"),
        default="auto",
        help="device for ML engines",
    )
    parser.add_argument("--model-name", default="ZhengPeng7/BiRefNet")
    parser.add_argument("--input-size", type=int, default=1024)
    parser.add_argument("--tolerance", type=float, default=None, help="classic engine RGB tolerance")
    parser.add_argument("--edge-softness", type=float, default=None, help="classic engine alpha blur radius")
    parser.add_argument("--bg-palette-size", type=int, default=4)
    parser.add_argument("--alpha-floor", type=int, default=24, help="set alpha values at or below N to 0")
    parser.add_argument("--alpha-ceiling", type=int, default=250, help="set alpha values at or above N to 255")
    parser.add_argument("--no-decontaminate", action="store_true", help="disable edge color cleanup")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="cutout",
        description="Model-aware background removal and alpha export tools.",
    )
    parser.add_argument("--version", action="version", version=f"cutout {__version__}")
    sub = parser.add_subparsers(dest="command", required=True)

    image = sub.add_parser("image", help="remove background from one image")
    image.add_argument("input", type=Path)
    image.add_argument("output", type=Path, nargs="?")
    image.add_argument("--alpha-output", type=Path)
    image.add_argument("--mask-output", type=Path)
    image.add_argument("--diagnostics", type=Path)
    image.add_argument("--preview-dir", type=Path)
    add_engine_options(image)

    batch = sub.add_parser("batch", help="remove backgrounds from a folder")
    batch.add_argument("input_dir", type=Path)
    batch.add_argument("output_dir", type=Path)
    batch.add_argument("--glob", default="*.png")
    batch.add_argument("--recursive", action="store_true")
    batch.add_argument("--diagnostics", type=Path)
    batch.add_argument(
        "--clean-output",
        action="store_true",
        help="delete the output directory before writing new PNGs",
    )
    batch.add_argument(
        "--save-extras",
        action="store_true",
        help="save per-image alpha, mask, diagnostics, and preview sidecars",
    )
    add_engine_options(batch)

    sub.add_parser("models", help="list known engines and model licensing notes")
    sub.add_parser("doctor", help="check local cutout dependencies")
    sub.add_parser("gui", help="open the desktop GUI")
    return parser


def options_from_args(args: argparse.Namespace) -> CutoutOptions:
    return CutoutOptions(
        engine=args.engine,
        preset=args.preset,
        device=args.device,
        model_name=args.model_name,
        input_size=args.input_size,
        tolerance=args.tolerance,
        edge_softness=args.edge_softness,
        bg_palette_size=args.bg_palette_size,
        alpha_floor=max(0, min(255, args.alpha_floor)),
        alpha_ceiling=max(0, min(255, args.alpha_ceiling)),
        decontaminate=not args.no_decontaminate,
        save_preview_dir=getattr(args, "preview_dir", None),
    )


def write_diagnostics(path: Path, payload) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def clean_output_dir(output_dir: Path, input_dir: Path) -> None:
    resolved_output = output_dir.resolve()
    resolved_input = input_dir.resolve()
    forbidden = {
        Path("/").resolve(),
        Path.cwd().resolve(),
        Path.home().resolve(),
        resolved_input,
    }
    if resolved_output in forbidden:
        raise CutoutError(f"Refusing to clean unsafe output directory: {output_dir}")
    if output_dir.exists() and output_dir.is_symlink():
        raise CutoutError(f"Refusing to clean symlink output directory: {output_dir}")
    if output_dir.exists() and not output_dir.is_dir():
        raise CutoutError(f"Output path exists and is not a directory: {output_dir}")
    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)


def cmd_image(args: argparse.Namespace) -> int:
    input_path = args.input
    if not input_path.is_file():
        raise CutoutError(f"Input file not found: {input_path}")

    output = args.output or default_output_path(input_path, "_cutout", "png")
    result = run_cutout(input_path, options_from_args(args))
    result.save(output, alpha_output=args.alpha_output, mask_output=args.mask_output)
    if args.preview_dir is not None:
        save_previews(result.rgba, args.preview_dir)
    if args.diagnostics is not None:
        write_diagnostics(args.diagnostics, result.diagnostics)

    print(f"Output:      {output}")
    if args.alpha_output is not None:
        print(f"Alpha:       {args.alpha_output}")
    if args.mask_output is not None:
        print(f"Mask:        {args.mask_output}")
    if args.preview_dir is not None:
        print(f"Previews:    {args.preview_dir}")
    print(f"Engine:      {result.diagnostics.get('engine', 'unknown')}")
    if "auto_fallback_reason" in result.diagnostics:
        print(f"Fallback:    {result.diagnostics['auto_fallback_reason']}", file=sys.stderr)
    return 0


def cmd_batch(args: argparse.Namespace) -> int:
    if not args.input_dir.is_dir():
        raise CutoutError(f"Input directory not found: {args.input_dir}")
    if args.clean_output:
        clean_output_dir(args.output_dir, args.input_dir)
    else:
        args.output_dir.mkdir(parents=True, exist_ok=True)

    pattern = f"**/{args.glob}" if args.recursive else args.glob
    inputs = sorted(path for path in args.input_dir.glob(pattern) if path.is_file())
    if not inputs:
        raise CutoutError(f"No images matched {pattern} under {args.input_dir}")

    options = options_from_args(args)
    report = []
    for input_path in inputs:
        relative = input_path.relative_to(args.input_dir)
        output = args.output_dir / relative.with_suffix(".png")
        alpha_output = None
        mask_output = None
        item_diagnostics = None
        preview_dir = None
        if args.save_extras:
            alpha_output = output.with_name(f"{output.stem}_alpha.png")
            mask_output = output.with_name(f"{output.stem}_mask.png")
            item_diagnostics = output.with_name(f"{output.stem}.json")
            preview_dir = output.with_name(f"{output.stem}_previews")

        result = run_cutout(input_path, options)
        result.save(output, alpha_output=alpha_output, mask_output=mask_output)
        if preview_dir is not None:
            save_previews(result.rgba, preview_dir)
        if item_diagnostics is not None:
            write_diagnostics(item_diagnostics, result.diagnostics)
        item = {"input": str(input_path), "output": str(output), **result.diagnostics}
        report.append(item)
        print(f"{input_path} -> {output} [{item.get('engine', 'unknown')}]")

    if args.diagnostics is not None:
        write_diagnostics(args.diagnostics, report)
    return 0


def cmd_models() -> int:
    for model in MODEL_INFOS:
        print(f"{model.key}")
        print(f"  label:   {model.label}")
        print(f"  role:    {model.role}")
        print(f"  license: {model.license}")
        print(f"  notes:   {model.notes}")
    return 0


def cmd_doctor() -> int:
    for status in collect_status():
        marker = "ok" if status.available else "missing"
        print(f"{marker:8} {status.name:12} {status.detail}")
    return 0


def cmd_gui() -> int:
    from .gui import run_gui

    return run_gui()


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "image":
            return cmd_image(args)
        if args.command == "batch":
            return cmd_batch(args)
        if args.command == "models":
            return cmd_models()
        if args.command == "doctor":
            return cmd_doctor()
        if args.command == "gui":
            return cmd_gui()
    except (CutoutError, ValueError, RuntimeError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2
    parser.error(f"Unknown command: {args.command}")
    return 2
