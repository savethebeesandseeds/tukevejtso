#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

input=""
colors=""
cluster=""
color=""
remaining=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--input)
      input="${2:-}"
      shift 2
      ;;
    -n|--n)
      colors="${2:-}"
      shift 2
      ;;
    -i|--idx)
      cluster="${2:-}"
      shift 2
      ;;
    -c|--color)
      color="${2:-}"
      shift 2
      ;;
    -h|--help)
      exec "$SCRIPT_DIR/image_tool.sh" cluster-transparent --help
      ;;
    *)
      remaining+=("$1")
      shift
      ;;
  esac
done

if [[ -z "$input" && ${#remaining[@]} -ge 1 ]]; then
  input="${remaining[0]}"
fi
if [[ -z "$colors" && ${#remaining[@]} -ge 2 ]]; then
  colors="${remaining[1]}"
fi
if [[ -z "$cluster" && ${#remaining[@]} -ge 3 ]]; then
  cluster="${remaining[2]}"
fi
if (( ${#remaining[@]} > 3 )); then
  echo "Error: unexpected extra arguments: ${remaining[*]:3}" >&2
  exit 1
fi

args=(cluster-transparent)
[[ -n "$input" ]] && args+=("$input")
[[ -n "$colors" ]] && args+=(--colors "$colors")
[[ -n "$cluster" ]] && args+=(--cluster "$cluster")
[[ -n "$color" ]] && args+=(--color "$color")

exec "$SCRIPT_DIR/image_tool.sh" "${args[@]}"
