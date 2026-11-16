"""Render the primitive-only branding SVG into platform launcher assets.

Requires Pillow for development; generated images are committed so normal
application builds do not depend on Python or a graphics toolchain.
"""
from pathlib import Path
import xml.etree.ElementTree as ET

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
BRANDING = ROOT / "assets" / "branding"


def render(size: int) -> Image.Image:
    scale = size * 4 / 1024
    image = Image.new("RGBA", (size * 4, size * 4))
    draw = ImageDraw.Draw(image)
    for element in ET.parse(BRANDING / "easyconnection.svg").getroot():
        tag = element.tag.rsplit("}", 1)[-1]
        if tag in ("title", "desc"):
            continue
        fill = element.attrib["fill"]
        if tag == "rect":
            x, y, width, height, radius = (
                float(element.attrib.get(key, 0)) * scale
                for key in ("x", "y", "width", "height", "rx")
            )
            draw.rounded_rectangle((x, y, x + width, y + height), radius, fill)
        elif tag == "polygon":
            points = [tuple(float(n) * scale for n in p.split(","))
                      for p in element.attrib["points"].split()]
            draw.polygon(points, fill)
        else:
            raise ValueError(f"Unsupported SVG primitive: {tag}")
    return image.resize((size, size), Image.Resampling.LANCZOS)


if __name__ == "__main__":
    render(512).save(BRANDING / "easyconnection.png")
    sizes = [(n, n) for n in (16, 20, 24, 32, 40, 48, 64, 128, 256)]
    render(256).save(BRANDING / "easyconnection.ico", sizes=sizes)
    resources = ROOT / "apps/mobile/android/app/src/main/res"
    for density, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96,
                          "xxhdpi": 144, "xxxhdpi": 192}.items():
        render(size).save(resources / f"mipmap-{density}/ic_launcher.png")
    print("Generated shared Windows icon and five Android launcher densities")
