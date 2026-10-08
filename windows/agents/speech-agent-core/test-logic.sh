#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Linux" || ! -f /.dockerenv ]]; then
  echo "Run test-logic.sh inside the managed Linux container." >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v rustc >/dev/null 2>&1; then
  echo "Rust is missing. Run setup-tests.sh inside the managed container." >&2
  exit 1
fi

test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
rustc --edition=2021 --test "$script_dir/src/speech_logic.rs" -o "$test_dir/speech-logic-tests"
"$test_dir/speech-logic-tests" "$@"
