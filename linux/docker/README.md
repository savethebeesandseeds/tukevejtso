# Debian Utility Container

This Docker image is the Linux runtime for `tukevejtso` utility scripts.

It uses `debian:latest`, installs the image/PDF dependencies used by
`linux/scripts/images`, and keeps a single long-running container named
`tukevejtso`.

## Windows Launcher

From the Windows toolkit:

```cmd
tk linux
```

Useful variants:

```cmd
tk linux -NoShell
tk linux -Rebuild
```

The launcher builds image `tukevejtso:debian-latest` when needed, creates the
container if it does not exist, mounts the repo at `/workspace/tukevejtso`, and
opens `/bin/bash`.

## Manual Commands

Build:

```bash
docker build -t tukevejtso:debian-latest -f linux/docker/Dockerfile linux/docker
```

Create and start the container:

```bash
docker create \
  --name tukevejtso \
  -it \
  -e TERM=xterm-256color \
  -e LANG=C.UTF-8 \
  -e LC_ALL=C.UTF-8 \
  -e COLORTERM=truecolor \
  -e FORCE_COLOR=1 \
  -v "$(pwd):/workspace/tukevejtso" \
  -w /workspace/tukevejtso/linux \
  tukevejtso:debian-latest \
  sleep infinity
docker start tukevejtso
docker exec -it tukevejtso /bin/bash
```
