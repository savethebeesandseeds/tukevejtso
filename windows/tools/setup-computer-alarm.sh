#!/usr/bin/env bash
set -euo pipefail
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this dependency setup as root inside the managed Debian container." >&2
  exit 1
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends mono-mcs mono-runtime libmono-system-windows-forms4.0-cil
