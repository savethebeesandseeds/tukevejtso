class CutoutError(RuntimeError):
    """Base error for user-facing cutout failures."""


class MissingDependencyError(CutoutError):
    """Raised when an optional provider cannot run in the current environment."""
