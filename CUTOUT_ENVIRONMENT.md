# Cutout Environment Recovery

This note recovers the image cutout environment used by `tk cutout` and
`linux/scripts/images/image_tool.sh cutout` without replacing its persistent
Python environment or model cache.

## What Gets Reused

- Base image: the already-local `debian:latest`
- Docker container: `tukevejtso`
- Persistent cutout volume: `tukevejtso-cutout-venvs`
- Cutout Python environment inside the container:
  `/opt/tukevejtso-venvs/cutout`
- Hugging Face model cache:
  `/opt/tukevejtso-venvs/huggingface`

The container uses the repository-root dependency-only `setup.sh`; there is no
project Dockerfile or Compose file. The Windows helper uses read-only host and
Docker runtime checks before giving a newly created container `--gpus all`.
The cutout CLI defaults to `--device auto`, so BiRefNet uses CUDA when
`torch.cuda.is_available()` is true and falls back to CPU otherwise.

## Recover The Container Safely

First confirm that the existing volume is present. The launcher intentionally
refuses to create an empty replacement under the same name:

```powershell
docker volume inspect tukevejtso-cutout-venvs
```

Then create or start only the `tukevejtso` container:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\tools\docker-tukevejtso-shell.ps1 -NoShell
```

The launcher reattaches `tukevejtso-cutout-venvs` at
`/opt/tukevejtso-venvs` with volume copying disabled. It never removes,
reinitializes, or downloads over that volume during normal recovery.

Verify Docker can see the GPU:

```powershell
docker exec tukevejtso nvidia-smi
docker inspect tukevejtso --format "{{json .HostConfig.DeviceRequests}}"
```

If GPU passthrough is working, `nvidia-smi` should list the NVIDIA GPU and the
inspect command should include a `gpu` device request.

## Existing Cutout Venv

Verify the preserved environment before considering any installation:

```powershell
docker exec tukevejtso test -x /opt/tukevejtso-venvs/cutout/bin/python
docker exec -w /workspace/tukevejtso/linux tukevejtso ./scripts/images/image_tool.sh cutout doctor
```

Do not run `bootstrap_cutout_env.sh --recreate` during container recovery. If
the preserved environment is missing or incompatible, stop and obtain explicit
approval before reinstalling PyTorch, GUI packages, or model data; those
downloads are large and are separate from the base-container setup.

## Verify CUDA

```powershell
docker exec -w /workspace/tukevejtso/linux tukevejtso /opt/tukevejtso-venvs/cutout/bin/python -c "import torch; print(torch.__version__); print(torch.version.cuda); print(torch.cuda.is_available()); print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'cpu')"
docker exec -w /workspace/tukevejtso/linux tukevejtso ./scripts/images/image_tool.sh cutout doctor
```

For a real smoke test:

```powershell
docker exec -w /workspace/tukevejtso/linux tukevejtso ./scripts/images/image_tool.sh cutout image "workspaces/images/tests/a (1).png" workspaces/images/gpu-smoke.png --engine birefnet --device auto --diagnostics workspaces/images/gpu-smoke.json
```

Check `workspaces/images/gpu-smoke.json`; the BiRefNet diagnostics should show
`"device": "cuda"` when CUDA is active.

## Normal Use

Use the Windows wrapper with GPU auto-selection:

```powershell
.\windows\toolkit.cmd cutout "C:\path\to\input-folder"
```

Or pass an output folder:

```powershell
.\windows\toolkit.cmd cutout "C:\path\to\input-folder" "C:\path\to\transparent-output"
```

Outputs are transparent PNGs by default. Temporary staging is cleaned
automatically unless `-KeepStage` is used with
`windows/tools/cutout-backgrounds.ps1`.

## Protected Recovery Rules

- A missing or mismatched volume is a stopping condition, not permission to
  create an empty replacement.
- Normal startup reuses an existing container, including a stopped one.
- A same-named unmanaged container is preserved and reported.
- Explicit recreation may replace only the inspected, managed `tukevejtso`
  container by immutable ID. It never removes the volume or host repository.
- Volume deletion and cutout-environment recreation are separate destructive
  operations and require an itemized plan plus explicit approval.
