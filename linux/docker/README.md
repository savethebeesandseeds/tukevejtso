# Debian Utility Container

The Linux runtime uses `debian:latest` directly. There is no project Dockerfile
or Compose file. The repository-root `setup.sh` is the authoritative,
dependency-only environment definition.

The launcher keeps one long-running container named `tukevejtso`, mounts this
repository at `/workspace/tukevejtso`, and reattaches the existing named volume
`tukevejtso-cutout-venvs` at `/opt/tukevejtso-venvs` with copying disabled.
That volume contains the cutout Python environment and Hugging Face cache.

## Windows Launcher

From the Windows toolkit:

```cmd
tk linux
```

Useful variants:

```cmd
tk linux -NoShell
tk linux -CpuOnly
```

Normal startup reuses an existing container, including a stopped one. On a new
container, the launcher runs `setup.sh`, waits for it to finish, and then opens
`/bin/bash`. GPU support is detected through read-only host and Docker runtime
inspection; no disposable probe container is created.

The launcher refuses to create an empty replacement when
`tukevejtso-cutout-venvs` is missing. A same-named unmanaged or mismatched
container is also preserved and reported instead of being replaced.

## Environment Replication

Inspect the required persistent volume first:

```bash
docker volume inspect tukevejtso-cutout-venvs
```

Then use the launcher. It creates only the missing named container from the
already-local `debian:latest` image and runs:

```bash
bash /workspace/tukevejtso/setup.sh
```

`setup.sh` installs only system dependencies and settings. It does not rebuild
the cutout virtual environment, download models, or operate project data.
Explicit recreation may replace only the inspected managed container; it never
removes the named volume or host-mounted files.
