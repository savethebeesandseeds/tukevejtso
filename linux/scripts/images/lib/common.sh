#!/usr/bin/env bash

die() {
  echo "Error: $*" >&2
  exit 1
}

warn() {
  echo "Warning: $*" >&2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"
}

setup_imagemagick() {
  if command -v magick >/dev/null 2>&1; then
    IM_CMD=(magick)
    IDENTIFY_CMD=(magick identify)
  elif command -v convert >/dev/null 2>&1 && command -v identify >/dev/null 2>&1; then
    IM_CMD=(convert)
    IDENTIFY_CMD=(identify)
  else
    die "ImageMagick not found (need 'magick' or 'convert'+'identify')."
  fi
}

is_integer() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

input_dir() {
  dirname -- "$1"
}

input_filename() {
  basename -- "$1"
}

input_stem() {
  local filename
  filename="$(input_filename "$1")"
  printf '%s\n' "${filename%.*}"
}

default_output_path() {
  local input="$1"
  local suffix="$2"
  local ext="${3:-${input##*.}}"
  printf '%s/%s%s.%s\n' "$(input_dir "$input")" "$(input_stem "$input")" "$suffix" "$ext"
}

ensure_parent_dir() {
  mkdir -p -- "$(dirname -- "$1")"
}

normalize_output_path() {
  local input="$1"
  local value="${2:-}"
  local suffix="$3"
  local ext="${4:-${input##*.}}"

  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
  else
    default_output_path "$input" "$suffix" "$ext"
  fi
}

print_result() {
  printf '%-12s %s\n' "$1" "$2"
}
