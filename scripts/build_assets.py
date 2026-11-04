"""Builds platform icon sets and in-app images from the brand sources in assets/brand.

Run from the repo root:  python scripts/build_assets.py
"""
import json
import shutil
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / "assets" / "brand"
APPLE_XC = ROOT / "apple" / "MuurMusic" / "Resources" / "Assets.xcassets"
WIDGET_XC = ROOT / "apple" / "MuurWidgets" / "Assets.xcassets"
WIN_ASSETS = ROOT / "windows" / "src" / "MuurMusic.App" / "Assets"

IMAGES = {
    "DefaultArtwork": "default-artwork.png",
    "EmptyLibrary": "empty-library.png",
    "EmptySearch": "empty-search.png",
    "Offline": "offline.png",
    "Logo": "logo.png",
}


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def rounded(icon: Image.Image, size: int, inset_ratio: float, radius_ratio: float) -> Image.Image:
    """Squircle-ish rounded rect on a transparent canvas (macOS / Windows tile style)."""
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    inner = round(size * (1 - 2 * inset_ratio))
    body = icon.convert("RGBA").resize((inner, inner), Image.LANCZOS)
    mask = Image.new("L", (inner * 4, inner * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, inner * 4 - 1, inner * 4 - 1), radius=round(inner * 4 * radius_ratio), fill=255
    )
    mask = mask.resize((inner, inner), Image.LANCZOS)
    off = (size - inner) // 2
    canvas.paste(body, (off, off), mask)
    return canvas


def apple_icons(icon: Image.Image) -> None:
    # iOS: single 1024 opaque image; Xcode generates the rest.
    ios_dir = APPLE_XC / "AppIcon.appiconset"
    ios_dir.mkdir(parents=True, exist_ok=True)
    icon.convert("RGB").save(ios_dir / "icon-ios-1024.png")
    images = [{"filename": "icon-ios-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}]
    # macOS: full size list with the Big Sur rounded-rect grid (824/1024 body).
    mac_master = rounded(icon, 1024, inset_ratio=100 / 1024, radius_ratio=0.2237)
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"icon-mac-{pt}@{scale}x.png"
            mac_master.resize((px, px), Image.LANCZOS).save(ios_dir / name)
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}"})
    write_json(ios_dir / "Contents.json", {"images": images, "info": {"author": "xcode", "version": 1}})

    write_json(APPLE_XC / "Contents.json", {"info": {"author": "xcode", "version": 1}})
    for name, src in IMAGES.items():
        d = APPLE_XC / f"{name}.imageset"
        d.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(BRAND / src, d / src)
        write_json(d / "Contents.json", {
            "images": [{"filename": src, "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
        })
    # Brand mark used inside the app (cat head, rounded) for headers / about screen.
    d = APPLE_XC / "BrandMark.imageset"
    d.mkdir(parents=True, exist_ok=True)
    rounded(icon, 512, 0, 0.2237).save(d / "brandmark.png")
    write_json(d / "Contents.json", {
        "images": [{"filename": "brandmark.png", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    })
    accent = APPLE_XC / "AccentColor.colorset"
    write_json(accent / "Contents.json", {
        "colors": [{"idiom": "universal", "color": {"color-space": "srgb", "components": {
            "red": "0xFF", "green": "0xB2", "blue": "0x3F", "alpha": "1.000"}}}],
        "info": {"author": "xcode", "version": 1},
    })
    bg = APPLE_XC / "LaunchBackground.colorset"
    write_json(bg / "Contents.json", {
        "colors": [{"idiom": "universal", "color": {"color-space": "srgb", "components": {
            "red": "0x16", "green": "0x12", "blue": "0x2B", "alpha": "1.000"}}}],
        "info": {"author": "xcode", "version": 1},
    })

    # Widget extension gets its own catalog with the artwork + brand mark.
    write_json(WIDGET_XC / "Contents.json", {"info": {"author": "xcode", "version": 1}})
    for name, src in (("DefaultArtwork", "default-artwork.png"),):
        d = WIDGET_XC / f"{name}.imageset"
        d.mkdir(parents=True, exist_ok=True)
        img = Image.open(BRAND / src).convert("RGB").resize((512, 512), Image.LANCZOS)
        img.save(d / src)
        write_json(d / "Contents.json", {"images": [{"filename": src, "idiom": "universal"}],
                                         "info": {"author": "xcode", "version": 1}})
    d = WIDGET_XC / "BrandMark.imageset"
    d.mkdir(parents=True, exist_ok=True)
    rounded(icon, 256, 0, 0.2237).save(d / "brandmark.png")
    write_json(d / "Contents.json", {"images": [{"filename": "brandmark.png", "idiom": "universal"}],
                                     "info": {"author": "xcode", "version": 1}})
    write_json(WIDGET_XC / "AccentColor.colorset" / "Contents.json", {
        "colors": [{"idiom": "universal", "color": {"color-space": "srgb", "components": {
            "red": "0xFF", "green": "0xB2", "blue": "0x3F", "alpha": "1.000"}}}],
        "info": {"author": "xcode", "version": 1},
    })


def windows_icons(icon: Image.Image) -> None:
    WIN_ASSETS.mkdir(parents=True, exist_ok=True)
    tile = rounded(icon, 256, inset_ratio=0.0, radius_ratio=0.18)
    tile.save(WIN_ASSETS / "MuurMusic.ico", sizes=[(16, 16), (20, 20), (24, 24), (32, 32), (40, 40),
                                                   (48, 48), (64, 64), (128, 128), (256, 256)])
    rounded(icon, 512, 0.0, 0.18).save(WIN_ASSETS / "AppLogo.png")
    for name, src in IMAGES.items():
        shutil.copyfile(BRAND / src, WIN_ASSETS / src)


def main() -> None:
    icon = Image.open(BRAND / "icon-1024.png").convert("RGBA").resize((1024, 1024), Image.LANCZOS)
    apple_icons(icon)
    windows_icons(icon)
    print("assets built")


if __name__ == "__main__":
    main()
