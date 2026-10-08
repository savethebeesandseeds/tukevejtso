#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Linux" || ! -f /.dockerenv ]]; then
  echo "Run setup-tests.sh inside the managed Linux container." >&2
  exit 1
fi
if [[ "$(id -u)" -ne 0 ]]; then
  echo "setup-tests.sh requires root inside the managed container." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends rustc gcc libc6-dev
