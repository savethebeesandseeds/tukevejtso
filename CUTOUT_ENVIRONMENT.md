# Cutout Environment Recovery

This note rebuilds the image cutout environment used by `tk cutout` and
`linux/scripts/images/image_tool.sh cutout`.

## What Gets Created

- Docker image: `tukevejtso:debian-latest`
- Docker container: `tukevejtso`
- Persistent cutout volume: `tukevejtso-cutout-venvs`
- Cutout Python environment inside the container:
  `/opt/tukevejtso-venvs/cutout`
- Hugging Face model cache:
  `/opt/tukevejtso-venvs/huggingface`

The Windows helper recreates the container with `--gpus all` when Docker can
see the GPU. The cutout CLI defaults to `--device auto`, so BiRefNet uses CUDA
when `torch.cuda.is_available()` is true and falls back to CPU otherwise.

## Recreate The Container

From the repository root on Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\tools\docker-tukevejtso-shell.ps1 -RecreateForGpu -NoShell
```

Verify Docker can see the GPU:

```powershell
docker exec tukevejtso nvidia-smi
docker inspect tukevejtso --format "{{json .HostConfig.DeviceRequests}}"
```

If GPU passthrough is working, `nvidia-smi` should list the NVIDIA GPU and the
inspect command should include a `gpu` device request.

## Bootstrap The Cutout Venv

Install the CUDA-enabled PyTorch stack, model dependencies, and GUI runtime:

```powershell
docker exec -w /workspace/tukevejtso/linux tukevejtso ./scripts/images/bootstrap_cutout_env.sh --ml-cuda --gui
```

The first CUDA install is large and can take a while. The bootstrap script uses
longer pip network timeouts by default. If the network is weak, raise them:

```powershell
docker exec -w /workspace/tukevejtso/linux `
  -e TUK_CUTOUT_PIP_TIMEOUT=300 `
  -e TUK_CUTOUT_PIP_RETRIES=60 `
  tukevejtso ./scripts/images/bootstrap_cutout_env.sh --ml-cuda --gui
```

The CUDA wheel defaults are:

```text
TUK_CUTOUT_TORCH_CUDA_INDEX_URL=https://download.pytorch.org/whl/cu128
TUK_CUTOUT_TORCH_CUDA_SPEC=torch==2.11.0+cu128
TUK_CUTOUT_TORCHVISION_CUDA_SPEC=torchvision==0.26.0+cu128
```

Override those environment variables only when the CUDA wheel set needs to be
changed.

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

## Full Reset

Use this only when the cutout venv or cache is corrupt:

```powershell
docker rm -f tukevejtso
docker volume rm tukevejtso-cutout-venvs
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\tools\docker-tukevejtso-shell.ps1 -RecreateForGpu -NoShell
docker exec -w /workspace/tukevejtso/linux tukevejtso ./scripts/images/bootstrap_cutout_env.sh --ml-cuda --gui
```

For a CPU-only rebuild:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\tools\docker-tukevejtso-shell.ps1 -CpuOnly -Recreate -NoShell
docker exec -w /workspace/tukevejtso/linux tukevejtso ./scripts/images/bootstrap_cutout_env.sh --ml --gui
```
