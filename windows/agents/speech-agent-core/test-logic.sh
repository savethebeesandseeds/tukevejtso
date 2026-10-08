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
for module in speech_logic response_history; do
  rustc --edition=2021 --test "$script_dir/src/$module.rs" -o "$test_dir/$module-tests"
  "$test_dir/$module-tests" "$@"
done
