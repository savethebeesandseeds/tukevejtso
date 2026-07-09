from __future__ import annotations

from pathlib import Path

from ..errors import MissingDependencyError
from ..image_io import open_rgba
from ..types import CutoutOptions, CutoutResult

_MODEL_CACHE = {}


def _select_device(torch, requested: str):
    if requested == "auto":
        if torch.cuda.is_available():
            return torch.device("cuda")
        return torch.device("cpu")
    if requested == "cuda" and not torch.cuda.is_available():
        raise MissingDependencyError("CUDA was requested, but torch.cuda.is_available() is false.")
    return torch.device(requested)


def _last_tensor(value):
    if hasattr(value, "logits"):
        return value.logits
    if isinstance(value, (list, tuple)):
        return _last_tensor(value[-1])
    return value


def _load_model(torch, AutoModelForImageSegmentation, model_name: str, device):
    key = (model_name, str(device))
    if key not in _MODEL_CACHE:
        model = AutoModelForImageSegmentation.from_pretrained(
            model_name,
            trust_remote_code=True,
        )
        model.to(device)
        if device.type == "cpu":
            model.float()
        model.eval()
        _MODEL_CACHE[key] = model
    return _MODEL_CACHE[key]


def run(input_path: Path, options: CutoutOptions) -> CutoutResult:
    try:
        import torch
        from PIL import Image
        from torchvision import transforms
        from transformers import AutoModelForImageSegmentation
    except ImportError as exc:
        raise MissingDependencyError(
            "BiRefNet needs the ML optional environment. Run "
            "`./scripts/images/bootstrap_cutout_env.sh --ml` from linux/ first."
        ) from exc

    image = open_rgba(input_path)
    rgb = image.convert("RGB")
    original_size = rgb.size
    device = _select_device(torch, options.device)
    model = _load_model(torch, AutoModelForImageSegmentation, options.model_name, device)

    size = options.input_size
    transform = transforms.Compose(
        [
            transforms.Resize((size, size), interpolation=transforms.InterpolationMode.BILINEAR),
            transforms.ToTensor(),
            transforms.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225]),
        ]
    )
    dtype = next(model.parameters()).dtype
    tensor = transform(rgb).unsqueeze(0).to(device=device, dtype=dtype)

    with torch.no_grad():
        prediction = _last_tensor(model(tensor))
        prediction = prediction.sigmoid().detach().float().cpu()[0]
        if prediction.ndim == 3:
            prediction = prediction[0]
        prediction = (prediction - prediction.min()) / (prediction.max() - prediction.min() + 1e-6)

    alpha = transforms.ToPILImage()(prediction).resize(original_size, Image.Resampling.LANCZOS)
    rgba = rgb.convert("RGBA")
    rgba.putalpha(alpha)
    hard_mask = alpha.point(lambda pixel: 255 if pixel >= 128 else 0, mode="L")

    return CutoutResult(
        rgba=rgba,
        alpha=alpha,
        hard_mask=hard_mask,
        diagnostics={
            "engine": "birefnet",
            "model": options.model_name,
            "device": str(device),
            "input_size": size,
            "preset": options.preset,
        },
    )
