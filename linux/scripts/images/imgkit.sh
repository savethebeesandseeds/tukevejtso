#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
imgkit.sh - compatibility wrapper around the cleaned-up toolkit

Preferred tools:
  ./scripts/image_tool.sh ...
  ./scripts/pdf_tool.sh ...

Legacy subcommands kept for compatibility:
  palette2
  dither_o8x8_6
  webp_to_jpg
  white_to_transparent
  cluster_then_transparent
  allowed_palette_clean
  mask_apply_alpha
  shrink_pdf
EOF
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  palette2)
    exec "$SCRIPT_DIR/image_tool.sh" palette "$@" --colors 2
    ;;
  dither_o8x8_6)
    exec "$SCRIPT_DIR/image_tool.sh" dither "$@" --colors 2 --pattern o8x8,6 --quality 100
    ;;
  webp_to_jpg)
    exec "$SCRIPT_DIR/image_tool.sh" webp-to-jpg "$@"
    ;;
  white_to_transparent)
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || $# -lt 1 ]]; then
      exec "$SCRIPT_DIR/image_tool.sh" white-to-transparent --help
    fi
    input="$1"
    fuzz="${2:-10%}"
    white_output="${3:-}"
    transparent_output="${4:-}"
    args=(white-to-transparent "$input" --fuzz "$fuzz")
    [[ -n "$transparent_output" ]] && args+=("$transparent_output")
    [[ -n "$white_output" ]] && args+=(--white-output "$white_output")
    exec "$SCRIPT_DIR/image_tool.sh" "${args[@]}"
    ;;
  cluster_then_transparent)
    exec "$SCRIPT_DIR/image_tool.sh" cluster-white-transparent "$@"
    ;;
  allowed_palette_clean)
    exec "$SCRIPT_DIR/image_tool.sh" allowed-palette-clean "$@"
    ;;
  mask_apply_alpha)
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || $# -lt 1 ]]; then
      exec "$SCRIPT_DIR/image_tool.sh" mask-alpha --help
    fi
    input="$1"
    threshold="${2:-99%}"
    dilate="${3:-2.0}"
    prefix="${4:-}"
    args=(mask-alpha "$input" --threshold "$threshold" --dilate "$dilate")
    if [[ -n "$prefix" ]]; then
      args+=(--mask-output "${prefix}_mask.png" --combined-output "${prefix}_combined.png" --output "${prefix}_transparent.png")
    fi
    exec "$SCRIPT_DIR/image_tool.sh" "${args[@]}"
    ;;
  shrink_pdf)
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || $# -lt 1 ]]; then
      exec "$SCRIPT_DIR/pdf_tool.sh" shrink --help
    fi
    input="$1"
    output="${2:-}"
    preset="${3:-/ebook}"
    args=(shrink "$input" --preset "$preset")
    [[ -n "$output" ]] && args+=("$output")
    exec "$SCRIPT_DIR/pdf_tool.sh" "${args[@]}"
    ;;
  help|-h|--help|"")
    usage
    ;;
  *)
    echo "Unknown imgkit subcommand: $cmd" >&2
    usage >&2
    exit 1
    ;;
esac
