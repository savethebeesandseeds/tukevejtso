#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LINUX_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
if [[ -n "${TUK_CUTOUT_PYTHON:-}" ]]; then
  VENV_PYTHON="$TUK_CUTOUT_PYTHON"
elif [[ -x /opt/tukevejtso-venvs/cutout/bin/python ]]; then
  VENV_PYTHON="/opt/tukevejtso-venvs/cutout/bin/python"
else
  VENV_PYTHON="$LINUX_DIR/.venvs/cutout/bin/python"
fi

if [[ -x "$VENV_PYTHON" ]]; then
  PYTHON="$VENV_PYTHON"
else
  PYTHON="${TUK_CUTOUT_FALLBACK_PYTHON:-python3}"
fi

export PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}"
if [[ -d /opt/tukevejtso-venvs ]]; then
  export HF_HOME="${HF_HOME:-/opt/tukevejtso-venvs/huggingface}"
else
  export HF_HOME="${HF_HOME:-$LINUX_DIR/.cache/huggingface}"
fi
exec "$PYTHON" -m cutout_engine "$@"
