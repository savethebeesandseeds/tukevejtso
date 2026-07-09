# tukevejtso for Linux

Portable Linux and WSL utility scripts.

This folder mirrors the top-level `windows/` platform split. It is for scripts
that are useful on Linux-like shells, even when they are launched manually from a
Windows workstation.

## Layout

```text
linux/
  scripts/
    images/      image, GIF, and PDF processing tools
  workspaces/    ignored local inputs, outputs, and scratch experiments
```

## Current Tools

- [Image Scripts](scripts/images/README.md): ImageMagick, GIF, palette,
  transparency, PDF helpers, and learned background removal.
- [Docker Runtime](docker/README.md): `debian:latest` utility container named
  `tukevejtso`.

## Adding More Utilities

Add future Linux utility families under `scripts/<topic>/`. If a tool needs
local inputs or generated outputs, keep them under `workspaces/` so Git only
tracks durable scripts and docs by default.
