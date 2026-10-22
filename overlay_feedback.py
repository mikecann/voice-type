"""Shared check geometry for the AppKit and Tk completion pills."""


def checkmark_points(progress: float) -> tuple[float, ...]:
    """Draw the short stroke first, then the longer rising stroke (46 x 24)."""
    progress = max(0.0, min(progress, 1.0))
    short = min(progress * 3.0, 1.0)
    long = max(0.0, (progress * 3.0 - 1.0) / 2.0)
    elbow = 12.0 + 8.0 * short
    tip = (20.0 + 16.0 * long, 20.0 - 16.0 * long) if long else (elbow, elbow)
    return (12.0, 12.0, elbow, elbow, *tip)
