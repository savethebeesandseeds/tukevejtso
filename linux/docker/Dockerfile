FROM debian:latest

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TERM=xterm-256color \
    COLORTERM=truecolor \
    FORCE_COLOR=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
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
        wget \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /workspace/tukevejtso

WORKDIR /workspace/tukevejtso/linux

CMD ["sleep", "infinity"]
