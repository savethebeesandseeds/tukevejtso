from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class ModelInfo:
    key: str
    label: str
    license: str
    role: str
    notes: str


MODEL_INFOS = [
    ModelInfo(
        key="classic",
        label="Classic border flood-fill",
        license="Repo-local",
        role="Fallback for flat or studio backgrounds",
        notes="Runs with Pillow and NumPy only. Not intended for hair, fur, glass, or complex scenes.",
    ),
    ModelInfo(
        key="birefnet",
        label="BiRefNet",
        license="MIT for the public project; verify selected weights before redistribution",
        role="Default serious automatic foreground segmentation",
        notes="Loaded from Hugging Face with transformers and trust_remote_code.",
    ),
    ModelInfo(
        key="ben2",
        label="BEN2",
        license="Check upstream model terms",
        role="Future alternate/refinement provider",
        notes="Planned after the first provider and benchmark harness are stable.",
    ),
    ModelInfo(
        key="bria-rmbg-2.0",
        label="BRIA RMBG-2.0",
        license="CC BY-NC 4.0 on Hugging Face; commercial use requires BRIA agreement",
        role="Optional licensed benchmark/provider",
        notes="Not bundled or used by default.",
    ),
]
