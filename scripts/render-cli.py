#!/usr/bin/env python3
"""Render CLI stills + GIF. Text matches src/main.m and src/cmd.c."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
DOCS.mkdir(exist_ok=True)

W, H = 720, 280
BG = (18, 18, 18)
FG = (230, 230, 230)
CMD = (255, 255, 255)
OK = (110, 220, 160)
FONT = "/System/Library/Fonts/SFNSMono.ttf"


def frame(lines):
    font = ImageFont.truetype(FONT, 22)
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    x, y = 28, 28
    for kind, text in lines:
        if kind == "prompt":
            d.text((x, y), "$", font=font, fill=OK)
            d.text((x + 22, y), text, font=font, fill=CMD)
        else:
            d.text((x, y), text, font=font, fill=FG)
        y += 36
    return im


def main():
    frames = [
        frame(
            [
                ("prompt", " ./gaze status"),
                ("out", "Insta360 Link 2  2e1a:4c04"),
                ("out", "zoom    100  (100–400)"),
                ("out", "pan     0  (-522000–522000)"),
                ("out", "tilt    0  (-324000–360000)"),
            ]
        ),
        frame(
            [
                ("prompt", " ./gaze center"),
                ("out", "2e1a:4c04 z=100 p=0 t=0"),
            ]
        ),
        frame(
            [
                ("prompt", " ./gaze zoom 200"),
                ("out", "2e1a:4c04 z=200 p=0 t=0"),
            ]
        ),
    ]
    frames[0].save(DOCS / "cli-status.png")
    frames[1].save(DOCS / "cli-center.png")
    frames[2].save(DOCS / "cli-zoom.png")
    frames[0].save(
        DOCS / "cli.gif",
        save_all=True,
        append_images=frames[1:],
        duration=[1600, 1400, 1600],
        loop=0,
    )


if __name__ == "__main__":
    main()
