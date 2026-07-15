#!/usr/bin/env python3
"""Compare simulator screenshots against the supplied reference screens.

For each screen with both a reference and a capture, writes to
tools/visual/output/:

    <name>-side-by-side.png   reference | actual, same height
    <name>-overlay.png        actual over reference at 50% alpha
    <name>-diff.png           per-pixel difference, amplified
    report.md                 mismatch percentage per screen

The mismatch number is what decides whether a screen is done — not a look at
the simulator. A screen is not "matching" because the same elements are
present; it matches when the diff says so.

Reference and capture are almost never the same pixel size (the references are
853px wide, an iPhone 17 Pro capture is 1206px), so everything is normalised to
the reference's dimensions before comparison. That resampling is itself a
source of small differences — treat single-digit mismatch on text-heavy screens
as noise, and look at the diff image rather than the number alone.

Usage:
    python3 tools/visual/compare.py [name ...]

Requires Pillow:  pip3 install --user Pillow
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    from PIL import Image, ImageChops
except ImportError:
    sys.exit(
        "Pillow is required.\n"
        "  pip3 install --user Pillow\n"
    )

ROOT = Path(__file__).resolve().parent
REFERENCE_DIR = ROOT / "reference"
ACTUAL_DIR = ROOT / "actual"
OUTPUT_DIR = ROOT / "output"

# The six supplied reference screens.
SCREENS = [
    "welcome",
    "discover",
    "speed-call",
    "call-ended",
    "match-chat",
    "profile",
]


def load(path: Path) -> Image.Image:
    return Image.open(path).convert("RGB")


def normalise(reference: Image.Image, actual: Image.Image) -> Image.Image:
    """Resample the capture to the reference's exact dimensions.

    Aspect ratios differ slightly between devices, so this can stretch by a
    percent or two. That is preferable to letterboxing, which would misalign
    everything below the inset and make the diff meaningless.
    """
    if actual.size == reference.size:
        return actual
    return actual.resize(reference.size, Image.LANCZOS)


def side_by_side(reference: Image.Image, actual: Image.Image) -> Image.Image:
    gap = 16
    canvas = Image.new(
        "RGB",
        (reference.width * 2 + gap, reference.height),
        (255, 255, 255),
    )
    canvas.paste(reference, (0, 0))
    canvas.paste(actual, (reference.width + gap, 0))
    return canvas


def overlay(reference: Image.Image, actual: Image.Image) -> Image.Image:
    return Image.blend(reference, actual, alpha=0.5)


def difference(reference: Image.Image, actual: Image.Image) -> tuple[Image.Image, float]:
    """Per-pixel difference, and the share of pixels that meaningfully differ."""
    diff = ImageChops.difference(reference, actual)

    # Amplify so small but real differences are visible; a raw diff of a
    # 2pt spacing error is nearly black and reads as a pass.
    amplified = diff.point(lambda value: min(255, value * 4))

    grey = diff.convert("L")
    # 24/255 ignores resampling and antialiasing noise while still catching a
    # genuine colour or position error.
    changed = sum(1 for pixel in grey.getdata() if pixel > 24)
    mismatch = changed / (grey.width * grey.height) * 100
    return amplified, mismatch


def compare(name: str) -> tuple[str, float | None, str]:
    reference_path = next(
        (p for p in (REFERENCE_DIR / f"{name}.png", REFERENCE_DIR / f"{name}.PNG") if p.exists()),
        None,
    )
    actual_path = next(
        (p for p in ACTUAL_DIR.glob(f"*{name}.png")),
        None,
    )

    if reference_path is None:
        return name, None, "no reference supplied"
    if actual_path is None:
        return name, None, "no capture — screen not built yet"

    reference = load(reference_path)
    actual = normalise(reference, load(actual_path))

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    side_by_side(reference, actual).save(OUTPUT_DIR / f"{name}-side-by-side.png")
    overlay(reference, actual).save(OUTPUT_DIR / f"{name}-overlay.png")
    diff_image, mismatch = difference(reference, actual)
    diff_image.save(OUTPUT_DIR / f"{name}-diff.png")

    return name, mismatch, "compared"


def main() -> int:
    names = sys.argv[1:] or SCREENS
    results = [compare(name) for name in names]

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    lines = [
        "# Visual comparison",
        "",
        "Mismatch is the share of pixels differing by more than 24/255 after the",
        "capture is resampled to the reference's dimensions. Resampling adds a",
        "floor of a few percent on text-heavy screens, so read the diff image —",
        "the number alone does not certify parity.",
        "",
        "| Screen | Mismatch | Status |",
        "|---|---|---|",
    ]
    for name, mismatch, status in results:
        value = f"{mismatch:.2f}%" if mismatch is not None else "—"
        lines.append(f"| {name} | {value} | {status} |")

    (OUTPUT_DIR / "report.md").write_text("\n".join(lines) + "\n")

    print("\n".join(lines))

    compared = [r for r in results if r[1] is not None]
    if not compared:
        print(
            "\nNothing compared. Save the reference screens as PNGs into\n"
            f"  {REFERENCE_DIR}\n"
            "named welcome.png, discover.png, speed-call.png, call-ended.png,\n"
            "match-chat.png, profile.png — then re-run.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
