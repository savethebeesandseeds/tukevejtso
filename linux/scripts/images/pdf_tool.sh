#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
pdf_tool.sh - PDF utilities

Usage:
  ./scripts/pdf_tool.sh <command> [options]

Commands:
  merge   OUTPUT.pdf INPUT1.pdf [INPUT2.pdf ...]
  shrink  INPUT.pdf [OUTPUT.pdf] [--preset /ebook]
EOF
}

usage_merge() {
  cat <<'EOF'
Usage:
  ./scripts/pdf_tool.sh merge OUTPUT.pdf INPUT1.pdf [INPUT2.pdf ...]
EOF
}

usage_shrink() {
  cat <<'EOF'
Usage:
  ./scripts/pdf_tool.sh shrink INPUT.pdf [OUTPUT.pdf] [--preset /ebook]
EOF
}

cmd_merge() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage_merge
    return 0
  fi

  local output="${1:-}"
  shift || true

  [[ -n "$output" ]] || { usage_merge >&2; return 1; }
  (($# >= 1)) || { usage_merge >&2; return 1; }

  need_cmd qpdf
  [[ ! -e "$output" ]] || die "Refusing to overwrite existing file: $output"
  ensure_parent_dir "$output"

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  local index=0 input rewritten
  for input in "$@"; do
    [[ -f "$input" ]] || die "Missing input PDF: $input"
    index=$((index + 1))
    rewritten="$tmpdir/$index.pdf"

    if ! qpdf --decrypt -- "$input" "$rewritten" 2>"$tmpdir/qpdf.$index.err"; then
      echo "Failed to process: $input" >&2
      echo "qpdf error:" >&2
      sed 's/^/  /' "$tmpdir/qpdf.$index.err" >&2
      die "If this file has a user password, provide a decrypted copy first."
    fi
  done

  qpdf --empty --pages "$tmpdir"/*.pdf -- "$output"
  print_result "Merged:" "$output"
}

cmd_shrink() {
  local input="" output="" preset="/ebook"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h) usage_shrink; return 0 ;;
      --preset) preset="${2:-}"; shift 2 ;;
      --*) die "Unknown option for shrink: $1" ;;
      *)
        if [[ -z "$input" ]]; then
          input="$1"
        elif [[ -z "$output" ]]; then
          output="$1"
        else
          die "Unexpected argument for shrink: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$input" ]] || { usage_shrink >&2; return 1; }
  need_cmd gs
  [[ -f "$input" ]] || die "Input PDF not found: $input"

  output="$(normalize_output_path "$input" "$output" "_small" "pdf")"
  ensure_parent_dir "$output"
  gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -dPDFSETTINGS="$preset" \
    -dNOPAUSE -dQUIET -dBATCH -sOutputFile="$output" "$input"
  print_result "Output:" "$output"
}

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    merge) cmd_merge "$@" ;;
    shrink) cmd_shrink "$@" ;;
    help|-h|--help|"") usage ;;
    *) die "Unknown command: $cmd" ;;
  esac
}

main "$@"
