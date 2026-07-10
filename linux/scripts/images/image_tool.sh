#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

IM_CMD=()
IDENTIFY_CMD=()

usage() {
  cat <<'EOF'
image_tool.sh - image utilities with a consistent CLI

Usage:
  ./scripts/image_tool.sh <command> [options]

Commands:
  inspect                   Write an image report with metadata and histograms
  palette                   Quantize an image to N colors
  dither                    Apply ordered dithering after quantization
  webp-to-jpg               Convert WEBP to JPG
  white-to-transparent      Deprecated: near-white alpha helper; prefer cutout
  mask-alpha                Deprecated: threshold alpha helper; prefer cutout
  cluster-transparent       Deprecated: color-cluster alpha helper; prefer cutout
  cutout                    Model-aware background removal CLI and GUI
  sprite-split              Split masked sprite sheets into padded individual PNGs
  hole-knockout             Remove configured transparent holes inside sprites
  allowed-palette-clean     Quantize to 6 colors, remove the dominant cluster, remap to the approved palette
  gif-cluster-transparent   Deprecated: frame cluster helper; prefer cutout for still images
  cluster-white-transparent Deprecated legacy grayscale cluster workflow
  edge-color-transparent    Deprecated experimental edge-connected color removal

Run `./scripts/image_tool.sh <command> --help` for command-specific options.
EOF
}

usage_inspect() {
  cat <<'EOF'
Usage:
  ./scripts/image_tool.sh inspect INPUT [REPORT]

Defaults:
  REPORT defaults to <input_dir>/<input_stem>_report.txt
EOF
}

usage_palette() {
  cat <<'EOF'
Usage:
  ./scripts/image_tool.sh palette INPUT [OUTPUT] [--colors N]
EOF
}

usage_dither() {
  cat <<'EOF'
Usage:
  ./scripts/image_tool.sh dither INPUT [OUTPUT] [--colors N] [--pattern PATTERN] [--quality Q]
EOF
}

usage_webp_to_jpg() {
  cat <<'EOF'
Usage:
  ./scripts/image_tool.sh webp-to-jpg INPUT.webp [OUTPUT.jpg]
EOF
}

usage_edge_color_transparent() {
  cat <<'EOF'
Usage:
  ./scripts/image_tool.sh edge-color-transparent INPUT [OUTPUT.png] [--color auto|black|white|#RRGGBB] [--tolerance N] [--connectivity 4|8] [--min-area N]

Experimental helper for manual comparison only. The usual transparency workflow
is `image_tool.sh cutout`.

Only pixels connected to the image border are removed. Use --min-area to also
remove large enclosed matching-color islands. This is not reliable for every
asset and should not be treated as a recommended cleanup method.
EOF
}

usage_white_to_transparent() {
  cat <<'EOF'
Usage:
  ./scripts/image_tool.sh white-to-transparent INPUT [OUTPUT.png] [--fuzz 10%] [--white-output FILE.jpg]

Deprecated for background removal. Prefer:
  ./scripts/images/image_tool.sh cutout image INPUT OUTPUT.png --engine birefnet --device auto
EOF
}

usage_mask_alpha() {
  cat <<'EOF'
Usage:
  ./scripts/image_tool.sh mask-alpha INPUT [--threshold 99%] [--dilate 2.0] [--mask-output FILE.png] [--combined-output FILE.png] [--output FILE.png]

Deprecated for background removal. Prefer `image_tool.sh cutout`.
EOF
}

usage_cluster_transparent() {
  cat <<'EOF'
Usage:
  ./scripts/image_tool.sh cluster-transparent INPUT [--colors N] [--cluster IDX] [--color "#RRGGBB"] [--quantized-output FILE.png] [--palette-output FILE.txt] [--mask-output FILE.png] [--output FILE.png] [--solid-output FILE.png]

Deprecated for background removal. Prefer `image_tool.sh cutout`.
EOF
}

usage_cutout() {
  cat <<'EOF'
Usage:
  ./scripts/image_tool.sh cutout <cutout-command> [options]

Examples:
  ./scripts/image_tool.sh cutout doctor
  ./scripts/image_tool.sh cutout models
  ./scripts/image_tool.sh cutout image INPUT.jpg OUTPUT.png --engine classic
  ./scripts/image_tool.sh cutout image INPUT.jpg OUTPUT.png --engine birefnet
  ./scripts/image_tool.sh cutout gui

Run `./scripts/images/cutout.sh --help` for the full cutout CLI.
EOF
}

usage_sprite_split() {
  cat <<'EOF'
Usage:
  ./scripts/image_tool.sh sprite-split INPUT_DIR OUTPUT_DIR --rows N --cols N [options]

Object-aware sheet splitter. It uses alpha/background masking to find each
sprite's real bounds, writes padded individual PNGs, and can also write
repacked sheets plus preview overlays.

Run `./scripts/images/split_sprite_sheets.py --help` for the full CLI.
EOF
}

usage_hole_knockout() {
  cat <<'EOF'
Usage:
  ./scripts/image_tool.sh hole-knockout CONFIG --input-dir DIR (--output-dir DIR | --in-place) [options]

Config-driven cleanup for enclosed holes that background removal cannot infer,
such as archways, windows, and handles. The config supplies erase shapes and
optional protect shapes so the pass only removes intended interior pixels.

Run `./scripts/images/transparent_hole_knockout.py --help` for the full CLI.
EOF
}

usage_allowed_palette_clean() {
  cat <<'EOF'
Usage:
  ./scripts/image_tool.sh allowed-palette-clean INPUT [OUTPUT] [--colors N]

Defaults:
  N defaults to 6
  OUTPUT defaults to <input_dir>/<input_stem>_clean.png

Workflow:
  1. Quantize to N colors
  2. Make the most common cluster transparent
  3. Remap remaining visible pixels to:
     #FEBC1D #066399 #0B9088 #B12F1F #282929
EOF
}

usage_gif_cluster_transparent() {
  cat <<'EOF'
Usage:
  ./scripts/image_tool.sh gif-cluster-transparent INPUT.gif OUTPUT.gif [--colors N] [--cluster IDX] [--no-pad-2to1]

Deprecated for general background removal. Keep only for legacy GIF experiments.
EOF
}

usage_cluster_white_transparent() {
  cat <<'EOF'
Usage:
  ./scripts/image_tool.sh cluster-white-transparent INPUT [COLORS] [OUT_PREFIX]

This is a legacy compatibility workflow:
  grayscale -> quantize -> force white -> transparent white

Deprecated for background removal. Prefer `image_tool.sh cutout`.
EOF
}

require_input_file() {
  local input="$1"
  [[ -f "$input" ]] || die "Input file not found: $input"
}

warn_deprecated_background_removal() {
  local command="$1"
  printf 'Warning: %s is deprecated for background removal; use `image_tool.sh cutout` or `tk cutout` instead.\n' "$command" >&2
}

palette_histogram() {
  local image="$1"
  local palette="$2"
  "${IM_CMD[@]}" "$image" -depth 8 -format "%c" histogram:info: \
    | sed -n 's/ *\([0-9]\+\):.*#\([0-9A-Fa-f]\{6\}\)\([0-9A-Fa-f]\{2\}\)\?.*/\1 #\2\3/p' \
    | sort -nr > "$palette"
}

color_match_expr() {
  local target_hex="$1"

  if [[ "$target_hex" =~ ^#[0-9A-Fa-f]{8}$ ]]; then
    local rr gg bb aa
    rr="${target_hex:1:2}"
    gg="${target_hex:3:2}"
    bb="${target_hex:5:2}"
    aa="${target_hex:7:2}"
    printf 'rgba(%d,%d,%d,%d)\n' "$((16#$rr))" "$((16#$gg))" "$((16#$bb))" "$((16#$aa))"
  else
    printf '%s\n' "$target_hex"
  fi
}

palette_color_at_index() {
  local palette="$1"
  local cluster_index="$2"
  awk -v want="$cluster_index" 'NR==want+1 { print $2 }' "$palette"
}

cluster_mask_from_quantized() {
  local quantized="$1"
  local mask="$2"
  local target_hex="$3"
  local target_match
  target_match="$(color_match_expr "$target_hex")"

  "${IM_CMD[@]}" "$quantized" \
    -fill black -opaque "$target_match" \
    -fill white +opaque black \
    -colorspace Gray -threshold 50% \
    "$mask"
}

mask_is_uniform() {
  local mask="$1"
  local extrema min max
  extrema=$("${IM_CMD[@]}" "$mask" -colorspace Gray -format "%[fx:minima] %[fx:maxima]\n" info:)
  min="${extrema% *}"
  max="${extrema#* }"
  [[ "$min" == "$max" ]]
}

apply_mask_as_alpha() {
  local input="$1"
  local mask="$2"
  local output="$3"
  "${IM_CMD[@]}" "$input" "$mask" -alpha Off -compose CopyOpacity -composite "$output"
}

build_palette_image() {
  local output="$1"
  shift
  (($# > 0)) || die "build_palette_image requires at least one color."

  local args=("${IM_CMD[@]}" -size "${#}x1" "xc:$1")
  shift

  local index=1
  local color
  for color in "$@"; do
    args+=(-fill "$color" -draw "color ${index},0 point")
    ((index += 1))
  done

  args+=("$output")
  "${args[@]}"
}

cmd_inspect() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || $# -lt 1 ]]; then
    usage_inspect
    [[ $# -ge 1 ]] || return 1
    return 0
  fi

  setup_imagemagick
  local input="$1"
  local output="${2:-$(default_output_path "$input" "_report" "txt")}"

  require_input_file "$input"
  ensure_parent_dir "$output"

  {
    echo "== ls =="
    ls -lah "$input"
    echo
    echo "== file =="
    file -b --mime "$input"
    echo
    echo "== identify summary =="
    "${IDENTIFY_CMD[@]}" -format "size=%wx%h  depth=%z  type=%[type]  colorspace=%[colorspace]  channels=%[channels]\n" "$input"
    echo
    echo "== identify -verbose =="
    "${IDENTIFY_CMD[@]}" -verbose "$input"
    echo
    echo "== alpha histogram =="
    "${IM_CMD[@]}" "$input" -alpha extract -format "%c" histogram:info: | head -n 200
    echo
    echo "== color histogram =="
    "${IM_CMD[@]}" "$input" -format "%c" histogram:info: | head -n 200
    echo
  } > "$output"

  print_result "Report:" "$output"
}

cmd_palette() {
  setup_imagemagick
  local input="" output="" colors="2"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h) usage_palette; return 0 ;;
      --colors) colors="${2:-}"; shift 2 ;;
      --*) die "Unknown option for palette: $1" ;;
      *)
        if [[ -z "$input" ]]; then
          input="$1"
        elif [[ -z "$output" ]]; then
          output="$1"
        else
          die "Unexpected argument for palette: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$input" ]] || { usage_palette >&2; return 1; }
  is_integer "$colors" || die "--colors must be an integer."
  require_input_file "$input"

  output="$(normalize_output_path "$input" "$output" "_palette${colors}" "png")"
  ensure_parent_dir "$output"
  "${IM_CMD[@]}" "$input" -dither None -colors "$colors" "$output"
  print_result "Palette:" "$output"
}

cmd_dither() {
  setup_imagemagick
  local input="" output="" colors="2" pattern="o8x8,6" quality="100"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h) usage_dither; return 0 ;;
      --colors) colors="${2:-}"; shift 2 ;;
      --pattern) pattern="${2:-}"; shift 2 ;;
      --quality) quality="${2:-}"; shift 2 ;;
      --*) die "Unknown option for dither: $1" ;;
      *)
        if [[ -z "$input" ]]; then
          input="$1"
        elif [[ -z "$output" ]]; then
          output="$1"
        else
          die "Unexpected argument for dither: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$input" ]] || { usage_dither >&2; return 1; }
  is_integer "$colors" || die "--colors must be an integer."
  require_input_file "$input"

  output="$(normalize_output_path "$input" "$output" "_dither" "png")"
  ensure_parent_dir "$output"
  "${IM_CMD[@]}" "$input" -colors "$colors" -colorspace sRGB -ordered-dither "$pattern" -quality "$quality" "$output"
  print_result "Dither:" "$output"
}

cmd_webp_to_jpg() {
  local input="${1:-}"
  local output="${2:-}"

  if [[ -z "$input" || "$input" == "--help" || "$input" == "-h" ]]; then
    usage_webp_to_jpg
    [[ -n "$input" ]] || return 1
    return 0
  fi

  need_cmd dwebp
  require_input_file "$input"

  output="$(normalize_output_path "$input" "$output" "" "jpg")"
  ensure_parent_dir "$output"
  dwebp "$input" -o "$output" >/dev/null
  print_result "JPEG:" "$output"
}

cmd_edge_color_transparent() {
  local input="" output="" color="auto" tolerance="0" connectivity="4" min_area="0"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h) usage_edge_color_transparent; return 0 ;;
      --color) color="${2:-}"; shift 2 ;;
      --tolerance) tolerance="${2:-}"; shift 2 ;;
      --connectivity) connectivity="${2:-}"; shift 2 ;;
      --min-area) min_area="${2:-}"; shift 2 ;;
      --*) die "Unknown option for edge-color-transparent: $1" ;;
      *)
        if [[ -z "$input" ]]; then
          input="$1"
        elif [[ -z "$output" ]]; then
          output="$1"
        else
          die "Unexpected argument for edge-color-transparent: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$input" ]] || { usage_edge_color_transparent >&2; return 1; }
  warn_deprecated_background_removal "edge-color-transparent"
  require_input_file "$input"
  is_integer "$tolerance" || die "--tolerance must be an integer."
  is_integer "$min_area" || die "--min-area must be an integer."
  [[ "$connectivity" == "4" || "$connectivity" == "8" ]] || die "--connectivity must be 4 or 8."

  need_cmd python3
  need_cmd ffmpeg
  need_cmd ffprobe

  output="$(normalize_output_path "$input" "$output" "_edge_transparent" "png")"
  ensure_parent_dir "$output"

  python3 "$SCRIPT_DIR/edge_color_transparent.py" \
    "$input" \
    "$output" \
    --color "$color" \
    --tolerance "$tolerance" \
    --connectivity "$connectivity" \
    --min-area "$min_area"
}

cmd_white_to_transparent() {
  setup_imagemagick
  local input="" output="" fuzz="10%" white_output=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h) usage_white_to_transparent; return 0 ;;
      --fuzz) fuzz="${2:-}"; shift 2 ;;
      --white-output) white_output="${2:-}"; shift 2 ;;
      --*) die "Unknown option for white-to-transparent: $1" ;;
      *)
        if [[ -z "$input" ]]; then
          input="$1"
        elif [[ -z "$output" ]]; then
          output="$1"
        else
          die "Unexpected argument for white-to-transparent: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$input" ]] || { usage_white_to_transparent >&2; return 1; }
  warn_deprecated_background_removal "white-to-transparent"
  require_input_file "$input"

  output="$(normalize_output_path "$input" "$output" "_transparent" "png")"
  ensure_parent_dir "$output"

  if [[ -n "$white_output" ]]; then
    ensure_parent_dir "$white_output"
    "${IM_CMD[@]}" "$input" -fuzz "$fuzz" -fill white -opaque white "$white_output"
    "${IM_CMD[@]}" "$white_output" -transparent white "$output"
    print_result "White:" "$white_output"
  else
    "${IM_CMD[@]}" "$input" -fuzz "$fuzz" -fill none -opaque white "$output"
  fi

  print_result "Output:" "$output"
}

cmd_mask_alpha() {
  setup_imagemagick
  local input="" threshold="99%" dilate="2.0"
  local mask_output="" combined_output="" output=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h) usage_mask_alpha; return 0 ;;
      --threshold) threshold="${2:-}"; shift 2 ;;
      --dilate) dilate="${2:-}"; shift 2 ;;
      --mask-output) mask_output="${2:-}"; shift 2 ;;
      --combined-output) combined_output="${2:-}"; shift 2 ;;
      --output) output="${2:-}"; shift 2 ;;
      --*) die "Unknown option for mask-alpha: $1" ;;
      *)
        if [[ -z "$input" ]]; then
          input="$1"
        else
          die "Unexpected argument for mask-alpha: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$input" ]] || { usage_mask_alpha >&2; return 1; }
  warn_deprecated_background_removal "mask-alpha"
  require_input_file "$input"

  mask_output="$(normalize_output_path "$input" "$mask_output" "_mask" "png")"
  combined_output="$(normalize_output_path "$input" "$combined_output" "_combined" "png")"
  output="$(normalize_output_path "$input" "$output" "_transparent" "png")"
  ensure_parent_dir "$mask_output"
  ensure_parent_dir "$combined_output"
  ensure_parent_dir "$output"

  "${IM_CMD[@]}" "$input" -colorspace Gray -auto-level -threshold "$threshold" \
    -morphology Dilate Disk:"$dilate" -negate -colors 2 +dither "$mask_output"
  "${IM_CMD[@]}" "$input" "$mask_output" -compose CopyOpacity -composite "$combined_output"
  "${IM_CMD[@]}" "$input" "$mask_output" -alpha Off -compose CopyOpacity -composite "$output"

  print_result "Mask:" "$mask_output"
  print_result "Combined:" "$combined_output"
  print_result "Output:" "$output"
}

cmd_cluster_transparent() {
  setup_imagemagick
  local input="" colors="2" cluster="0" color=""
  local quantized_output="" palette_output="" mask_output="" output="" solid_output=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h) usage_cluster_transparent; return 0 ;;
      --colors) colors="${2:-}"; shift 2 ;;
      --cluster) cluster="${2:-}"; shift 2 ;;
      --color) color="${2:-}"; shift 2 ;;
      --quantized-output) quantized_output="${2:-}"; shift 2 ;;
      --palette-output) palette_output="${2:-}"; shift 2 ;;
      --mask-output) mask_output="${2:-}"; shift 2 ;;
      --output) output="${2:-}"; shift 2 ;;
      --solid-output) solid_output="${2:-}"; shift 2 ;;
      --*) die "Unknown option for cluster-transparent: $1" ;;
      *)
        if [[ -z "$input" ]]; then
          input="$1"
        else
          die "Unexpected argument for cluster-transparent: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$input" ]] || { usage_cluster_transparent >&2; return 1; }
  warn_deprecated_background_removal "cluster-transparent"
  is_integer "$colors" || die "--colors must be an integer."
  is_integer "$cluster" || die "--cluster must be an integer."
  require_input_file "$input"

  quantized_output="$(normalize_output_path "$input" "$quantized_output" "_N${colors}" "png")"
  palette_output="$(normalize_output_path "$input" "$palette_output" "_palette_N${colors}" "txt")"
  mask_output="$(normalize_output_path "$input" "$mask_output" "_N${colors}_mask_idx${cluster}" "png")"
  output="$(normalize_output_path "$input" "$output" "_transparent_idx${cluster}" "png")"

  if [[ -n "$color" && -z "$solid_output" ]]; then
    local color_tag
    color_tag="$(printf '%s' "$color" | sed 's/^#//; s/[^0-9A-Fa-f]/_/g')"
    solid_output="$(normalize_output_path "$input" "" "_solid_${color_tag}_idx${cluster}" "png")"
  fi

  ensure_parent_dir "$quantized_output"
  ensure_parent_dir "$palette_output"
  ensure_parent_dir "$mask_output"
  ensure_parent_dir "$output"
  [[ -z "$solid_output" ]] || ensure_parent_dir "$solid_output"

  "${IM_CMD[@]}" "$input" -dither None -colors "$colors" "$quantized_output"
  palette_histogram "$quantized_output" "$palette_output"

  local total_clusters target_hex
  total_clusters="$(wc -l < "$palette_output" | tr -d ' ')"
  [[ "$total_clusters" -gt 0 ]] || die "No colors found in histogram."
  (( cluster < total_clusters )) || die "--cluster $cluster is out of range; palette has $total_clusters entries."

  target_hex="$(palette_color_at_index "$palette_output" "$cluster")"
  [[ -n "$target_hex" ]] || die "Could not read cluster $cluster from $palette_output"

  cluster_mask_from_quantized "$quantized_output" "$mask_output" "$target_hex"
  mask_is_uniform "$mask_output" && die "Generated mask is uniform; try a different cluster or color count."

  apply_mask_as_alpha "$input" "$mask_output" "$output"

  if [[ -n "$color" ]]; then
    "${IM_CMD[@]}" "$input" -alpha Off -fill "$color" -colorize 100 \
      "$mask_output" -compose CopyOpacity -composite "$solid_output"
    print_result "Solid:" "$solid_output"
  fi

  print_result "Quantized:" "$quantized_output"
  print_result "Palette:" "$palette_output"
  print_result "Mask:" "$mask_output"
  print_result "Output:" "$output"
}

cmd_cutout() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage_cutout
    return 0
  fi

  need_cmd python3
  "$SCRIPT_DIR/cutout.sh" "$@"
}

cmd_allowed_palette_clean() {
  setup_imagemagick
  local input="" output="" colors="6"
  local tmp="" quantized="" palette_txt="" mask="" palette_png="" remapped=""
  local target_hex=""
  local -a allowed_colors=("#FEBC1D" "#066399" "#0B9088" "#B12F1F" "#282929")

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h) usage_allowed_palette_clean; return 0 ;;
      --colors) colors="${2:-}"; shift 2 ;;
      --*) die "Unknown option for allowed-palette-clean: $1" ;;
      *)
        if [[ -z "$input" ]]; then
          input="$1"
        elif [[ -z "$output" ]]; then
          output="$1"
        else
          die "Unexpected argument for allowed-palette-clean: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$input" ]] || { usage_allowed_palette_clean >&2; return 1; }
  is_integer "$colors" || die "--colors must be an integer."
  require_input_file "$input"

  output="$(normalize_output_path "$input" "$output" "_clean" "png")"
  ensure_parent_dir "$output"

  tmp="$(mktemp -d -t allowed-palette-clean.XXXXXX)"
  trap "rm -rf -- '$tmp'" EXIT

  quantized="$tmp/quantized.png"
  palette_txt="$tmp/palette.txt"
  mask="$tmp/mask.png"
  palette_png="$tmp/allowed_palette.png"
  remapped="$tmp/remapped.png"

  "${IM_CMD[@]}" "$input" -dither None -colors "$colors" "$quantized"
  palette_histogram "$quantized" "$palette_txt"
  target_hex="$(palette_color_at_index "$palette_txt" 0)"
  [[ -n "$target_hex" ]] || die "Could not determine the dominant cluster."

  cluster_mask_from_quantized "$quantized" "$mask" "$target_hex"
  mask_is_uniform "$mask" && die "Generated mask is uniform; dominant cluster covers the whole image."

  build_palette_image "$palette_png" "${allowed_colors[@]}"
  "${IM_CMD[@]}" "$quantized" +dither -remap "$palette_png" "$remapped"
  apply_mask_as_alpha "$remapped" "$mask" "$output"

  print_result "Output:" "$output"
  print_result "Removed:" "$target_hex"
}

cmd_gif_cluster_transparent() {
  setup_imagemagick
  local input="" output="" colors="5" cluster="0" pad_to_ratio="1"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h) usage_gif_cluster_transparent; return 0 ;;
      --colors) colors="${2:-}"; shift 2 ;;
      --cluster) cluster="${2:-}"; shift 2 ;;
      --no-pad-2to1) pad_to_ratio="0"; shift ;;
      --*) die "Unknown option for gif-cluster-transparent: $1" ;;
      *)
        if [[ -z "$input" ]]; then
          input="$1"
        elif [[ -z "$output" ]]; then
          output="$1"
        else
          die "Unexpected argument for gif-cluster-transparent: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$input" && -n "$output" ]] || { usage_gif_cluster_transparent >&2; return 1; }
  warn_deprecated_background_removal "gif-cluster-transparent"
  is_integer "$colors" || die "--colors must be an integer."
  is_integer "$cluster" || die "--cluster must be an integer."
  require_input_file "$input"
  ensure_parent_dir "$output"

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/frames" "$tmp/processed"

  "${IDENTIFY_CMD[@]}" -format "%T\n" "$input" > "$tmp/delays.txt"
  "${IM_CMD[@]}" "$input" -coalesce +repage "$tmp/frames/frame_%04d.png"

  shopt -s nullglob
  local frames=("$tmp/frames"/frame_*.png)
  ((${#frames[@]})) || die "No frames extracted from GIF."

  local frame base quantized palette mask target_hex orig_alpha combined_alpha with_alpha height width target_width out_frame
  for frame in "${frames[@]}"; do
    base="$(basename "$frame" .png)"
    quantized="$tmp/${base}_q.png"
    palette="$tmp/${base}_palette.txt"
    mask="$tmp/${base}_mask.png"
    orig_alpha="$tmp/${base}_orig_alpha.png"
    combined_alpha="$tmp/${base}_combined_alpha.png"
    with_alpha="$tmp/${base}_with_alpha.png"
    out_frame="$tmp/processed/${base}.png"

    "${IM_CMD[@]}" "$frame" -alpha off +dither -colors "$colors" +repage "$quantized"
    palette_histogram "$quantized" "$palette"
    target_hex="$(palette_color_at_index "$palette" "$cluster")"
    [[ -n "$target_hex" ]] || die "Frame $frame does not have cluster index $cluster."

    cluster_mask_from_quantized "$quantized" "$mask" "$target_hex"
    "${IM_CMD[@]}" "$frame" -alpha extract +repage "$orig_alpha"
    "${IM_CMD[@]}" "$orig_alpha" "$mask" -compose multiply -composite +repage "$combined_alpha"
    "${IM_CMD[@]}" "$frame" "$combined_alpha" -compose CopyOpacity -composite +repage "$with_alpha"

    if [[ "$pad_to_ratio" == "1" ]]; then
      height="$("${IDENTIFY_CMD[@]}" -format '%h' "$with_alpha")"
      width="$("${IDENTIFY_CMD[@]}" -format '%w' "$with_alpha")"
      target_width=$((2 * height))

      if (( width < target_width )); then
        "${IM_CMD[@]}" "$with_alpha" -background none -gravity center -extent "${target_width}x${height}" +repage "$out_frame"
      else
        "${IM_CMD[@]}" "$with_alpha" +repage "$out_frame"
      fi
    else
      "${IM_CMD[@]}" "$with_alpha" +repage "$out_frame"
    fi
  done

  readarray -t delays < "$tmp/delays.txt"
  local processed=("$tmp/processed"/frame_*.png)
  ((${#processed[@]})) || die "No processed GIF frames produced."

  local cmd=("${IM_CMD[@]}" -dispose background)
  local i delay
  for i in "${!processed[@]}"; do
    delay="${delays[$i]:-6}"
    cmd+=(-delay "$delay" "${processed[$i]}")
  done
  cmd+=(-loop 0 -alpha on -layers OptimizeTransparency "$output")
  "${cmd[@]}"

  print_result "Output:" "$output"
}

cmd_cluster_white_transparent() {
  setup_imagemagick
  local input="${1:-}" colors="${2:-3}" prefix="${3:-}"

  if [[ -z "$input" || "$input" == "--help" || "$input" == "-h" ]]; then
    usage_cluster_white_transparent
    [[ -n "$input" ]] || return 1
    return 0
  fi

  is_integer "$colors" || die "COLORS must be an integer."
  warn_deprecated_background_removal "cluster-white-transparent"
  require_input_file "$input"

  if [[ -n "$prefix" ]]; then
    :
  else
    prefix="$(input_dir "$input")/$(input_stem "$input")"
  fi

  local clustered="${prefix}_clustered.png"
  local white_output="${prefix}_clustered.jpg"
  local transparent="${prefix}_transparent.png"

  ensure_parent_dir "$clustered"
  "${IM_CMD[@]}" "$input" -colorspace Gray +level-colors white, +dither -colors "$colors" "$clustered"
  "${IM_CMD[@]}" "$clustered" -fill white -opaque white "$white_output"
  "${IM_CMD[@]}" "$white_output" -transparent white "$transparent"

  print_result "Clustered:" "$clustered"
  print_result "White:" "$white_output"
  print_result "Output:" "$transparent"
}

cmd_sprite_split() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || $# -lt 1 ]]; then
    usage_sprite_split
    [[ $# -ge 1 ]] || return 1
    return 0
  fi

  python3 "$SCRIPT_DIR/split_sprite_sheets.py" "$@"
}

cmd_hole_knockout() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || $# -lt 1 ]]; then
    usage_hole_knockout
    [[ $# -ge 1 ]] || return 1
    return 0
  fi

  python3 "$SCRIPT_DIR/transparent_hole_knockout.py" "$@"
}

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    inspect) cmd_inspect "$@" ;;
    palette) cmd_palette "$@" ;;
    dither) cmd_dither "$@" ;;
    webp-to-jpg) cmd_webp_to_jpg "$@" ;;
    edge-color-transparent) cmd_edge_color_transparent "$@" ;;
    white-to-transparent) cmd_white_to_transparent "$@" ;;
    mask-alpha) cmd_mask_alpha "$@" ;;
    cluster-transparent) cmd_cluster_transparent "$@" ;;
    cutout) cmd_cutout "$@" ;;
    sprite-split) cmd_sprite_split "$@" ;;
    hole-knockout) cmd_hole_knockout "$@" ;;
    allowed-palette-clean) cmd_allowed_palette_clean "$@" ;;
    gif-cluster-transparent) cmd_gif_cluster_transparent "$@" ;;
    cluster-white-transparent) cmd_cluster_white_transparent "$@" ;;
    help|-h|--help|"") usage ;;
    *) die "Unknown command: $cmd" ;;
  esac
}

main "$@"
