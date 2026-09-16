#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "setup.sh must run as root inside the Debian environment." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  bash \
  ca-certificates \
  coreutils \
  curl \
  ffmpeg \
  file \
  findutils \
  ghostscript \
  git \
  imagemagick \
  jq \
  less \
  libwebp-dev \
  nano \
  poppler-utils \
  procps \
  python3 \
  python3-pip \
  python3-venv \
  qpdf \
  ripgrep \
  sed \
  tar \
  tree \
  unzip \
  vim-tiny \
  webp \
  wget

apt-get clean
rm -rf /var/lib/apt/lists/*
