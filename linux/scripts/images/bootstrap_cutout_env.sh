#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LINUX_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_VENV_DIR="$LINUX_DIR/.venvs/cutout"
if mkdir -p /opt/tukevejtso-venvs 2>/dev/null; then
  DEFAULT_VENV_DIR="/opt/tukevejtso-venvs/cutout"
fi
VENV_DIR="${TUK_CUTOUT_VENV:-$DEFAULT_VENV_DIR}"
PYTHON_BIN="${TUK_CUTOUT_BOOTSTRAP_PYTHON:-python3}"

install_ml=0
install_ml_cuda=0
install_gui=0
recreate=0

usage() {
  cat <<'EOF'
bootstrap_cutout_env.sh - create the Python environment for cutout tools

Usage:
  ./scripts/images/bootstrap_cutout_env.sh [--ml] [--ml-cuda] [--gui] [--all] [--recreate]

Options:
  --ml        install CPU PyTorch/Transformers dependencies for BiRefNet
  --ml-cuda   install default PyTorch wheels instead of CPU-only wheels
  --gui       install PySide6 for the GUI scaffold
  --all       install core, ML, and GUI dependencies
  --recreate  delete and recreate the venv
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --ml) install_ml=1; shift ;;
    --ml-cuda) install_ml=1; install_ml_cuda=1; shift ;;
    --gui) install_gui=1; shift ;;
    --all) install_ml=1; install_gui=1; shift ;;
    --recreate) recreate=1; shift ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$recreate" == "1" && -d "$VENV_DIR" ]]; then
  rm -rf -- "$VENV_DIR"
fi

if [[ ! -d "$VENV_DIR" ]]; then
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

PIP=(
  "$VENV_DIR/bin/python"
  -m pip
  --disable-pip-version-check
  --no-color
  --timeout "${TUK_CUTOUT_PIP_TIMEOUT:-120}"
  --retries "${TUK_CUTOUT_PIP_RETRIES:-20}"
)
"${PIP[@]}" install --progress-bar off -r "$SCRIPT_DIR/cutout-requirements.txt"

if [[ "$install_ml" == "1" ]]; then
  if [[ "$install_ml_cuda" == "1" ]]; then
    cuda_index_url="${TUK_CUTOUT_TORCH_CUDA_INDEX_URL:-https://download.pytorch.org/whl/cu128}"
    torch_cuda_spec="${TUK_CUTOUT_TORCH_CUDA_SPEC:-torch==2.11.0+cu128}"
    torchvision_cuda_spec="${TUK_CUTOUT_TORCHVISION_CUDA_SPEC:-torchvision==0.26.0+cu128}"
    "${PIP[@]}" install --progress-bar off --force-reinstall --index-url "$cuda_index_url" "$torch_cuda_spec" "$torchvision_cuda_spec"
    "${PIP[@]}" install --progress-bar off -r "$SCRIPT_DIR/cutout-requirements-ml.txt"
  else
    "${PIP[@]}" install --progress-bar off --index-url https://download.pytorch.org/whl/cpu torch torchvision
    "${PIP[@]}" install --progress-bar off -r "$SCRIPT_DIR/cutout-requirements-ml.txt"
  fi
fi

if [[ "$install_gui" == "1" ]]; then
  "${PIP[@]}" install --progress-bar off -r "$SCRIPT_DIR/cutout-requirements-gui.txt"
fi

echo "Cutout environment ready: $VENV_DIR"
echo "Try: ./scripts/images/image_tool.sh cutout doctor"
