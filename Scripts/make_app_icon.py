"""Generate Woodshed's opaque 1024px iOS icon, using only Pillow."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

out = Path(__file__).resolve().parents[1] / "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
image = Image.new("RGB", (1024, 1024), "#15241E")
draw = ImageDraw.Draw(image)
# Five practice-ledger staves, with an accented note rather than a stock logo.
for y in (360, 432, 504, 576, 648):
    draw.rounded_rectangle((142, y, 882, y + 10), radius=5, fill="#4D6E56")
draw.ellipse((398, 450, 565, 551), fill="#E5B75C")
draw.polygon(((542, 487), (564, 487), (564, 289), (542, 289)), fill="#E5B75C")
draw.arc((545, 257, 715, 354), 205, 355, fill="#E5B75C", width=23)
image.save(out, format="PNG", optimize=True)
print(f"icon={out} size={image.size} mode={image.mode} bytes={out.stat().st_size}")
