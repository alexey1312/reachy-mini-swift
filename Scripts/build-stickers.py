#!/usr/bin/env python3
"""Builds the iMessage sticker catalogue from the art under `art/stickers`.

Sixteen Reachy characters as animated APNGs, in the one sticker pack iOS permits an
app to embed. Two things about them are worth knowing before changing anything here.

**Apple's limit is 500 KB per sticker file**, and a two-second loop at the source's
own 30 fps is nowhere near it — a 408 px RGBA APNG of `builder-hammer` measures
2.9 MB. What buys the margin back is *palette* mode: one shared 256-colour table for
the whole animation, written as 8-bit indexed PNG rather than 32-bit RGBA. Same
picture, roughly a third of the bytes. Pillow cannot hand an existing palette to
`quantize` on an RGBA image, so the frames are stacked into one tall montage,
quantised together, and cut apart again — which is what makes them share a palette.

**The frame rate is per file, not global.** At 408 px and a full palette, twelve of
the sixteen fit at 15 fps and the rest do not; `builder-hammer` needs 10. So each
sticker walks `BUDGET_LADDER` until one rung fits, and the script fails rather than
shipping a file Apple will reject at upload.

Usage: `mise run stickers:build`. Needs ffmpeg on PATH (deliberately not pinned —
this runs by hand when the art changes, and its output is committed).
"""

from __future__ import annotations

import io
import json
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / "art" / "stickers"

# Apple's ceiling, and the one number this whole script is arranged around.
MAX_STICKER_BYTES = 500 * 1024

# `grid-size` is a pack-level property, so both packs commit to one size. Regular is
# 408 px at @3x: a clean downscale from the 512 px source rather than an upscale, and
# the largest of the three that leaves the animations room under the byte limit.
GRID_SIZE = "regular"
STICKER_PX = 408

# Tried in order, first one under the limit wins. Frame rate goes first because a
# dropped frame is less visible than a flattened palette on artwork this smooth.
BUDGET_LADDER = [(15, 256), (12, 256), (10, 256), (10, 192), (8, 128)]

# name, emoji, still, animation, what the sticker shows, how it moves
CHARACTERS = [
    ("astronaut", "🚀", "astronaut.png", "astronaut-float.webm",
     "Reachy Mini in a space helmet", "drifting in zero gravity"),
    ("builder", "👷", "builder.png", "builder-hammer.webm",
     "Reachy Mini in a hard hat", "swinging a hammer"),
    ("captain", "⚓", "captain.png", "captain-sail.webm",
     "Reachy Mini in a captain's cap", "rolling with the swell"),
    ("cooking-chief", "👨‍🍳", "cooking-chief.png", "cooking-chief-laugh.webm",
     "Reachy Mini in a chef's toque", "laughing"),
    ("cowboy", "🤠", "cowboy.png", "cowboy-swagger.webm",
     "Reachy Mini in a cowboy hat", "swaggering"),
    ("doctor", "🩺", "doctor.png", "doctor-think.webm",
     "Reachy Mini with a head mirror", "tilting its head in thought"),
    ("explorer", "🧭", "explorer.png", "explorer-scan.webm",
     "Reachy Mini in an explorer's hat", "scanning left and right"),
    ("farmer", "🌾", "farmer.png", "farmer-breathe.webm",
     "Reachy Mini in a straw hat", "breathing slowly"),
    ("fisherman", "🎣", "fisherman.png", "fisherman-bob.webm",
     "Reachy Mini in a fishing hat", "bobbing on the water and getting a bite"),
    ("hacker", "💻", "hacker.png", "hacker-shake.webm",
     "Reachy Mini in a hoodie", "shaking its head no"),
    ("jazzman", "🎷", "jazzman.png", "jazzman-groove.webm",
     "Reachy Mini in a jazz hat", "swaying to the beat"),
    ("magician", "🪄", "magician.png", "magician-pop.webm",
     "Reachy Mini in a magician's hat", "popping into view"),
    ("plumber", "🔧", "plumber.png", "plumber-nod.webm",
     "Reachy Mini in a plumber's cap", "nodding that it is fixed"),
    ("rich", "🎩", "rich.png", "rich-strut.webm",
     "Reachy Mini in a top hat", "drawing itself up"),
    ("student", "🎓", "student.png", "student-raise.webm",
     "Reachy Mini in a graduation cap", "shooting its hand up"),
    ("update-box", "📦", "update-box.png", "box-unbox.webm",
     "Reachy Mini in a delivery box", "landing on the table with a wobble"),
]

# Graphite, from `ReachyTheme.palette` — the theme the app falls back to and the one
# the shipping icon and the docs site both use. Duplicated rather than read, the same
# trade `Scripts/render-app-icon.swift` makes: a `swift` script cannot link
# ReachyDesign, and neither can this one.
GRADIENT_TOP = 0x9AA6B8
GRADIENT_BOTTOM = 0x3E4757
SWATCH_STOP_INSET = 0.17
SWATCH_HIGHLIGHT = 0.25
SWATCH_SHADE = -0.15

# Every slot Xcode 27's Sticker Pack template declares, verbatim. Note the marketing
# icon is 1024x768 and not the 1024x1024 the Human Interface Guidelines table shows —
# the template is what `actool` reads, so the template wins.
ICON_SLOTS = [
    {"idiom": "iphone", "size": "29x29", "scale": "2x"},
    {"idiom": "iphone", "size": "29x29", "scale": "3x"},
    {"idiom": "iphone", "size": "60x45", "scale": "2x"},
    {"idiom": "iphone", "size": "60x45", "scale": "3x"},
    {"idiom": "ipad", "size": "29x29", "scale": "2x"},
    {"idiom": "ipad", "size": "67x50", "scale": "2x"},
    {"idiom": "ipad", "size": "74x55", "scale": "2x"},
    {"idiom": "universal", "size": "27x20", "scale": "2x", "platform": "ios"},
    {"idiom": "universal", "size": "27x20", "scale": "3x", "platform": "ios"},
    {"idiom": "universal", "size": "32x24", "scale": "2x", "platform": "ios"},
    {"idiom": "universal", "size": "32x24", "scale": "3x", "platform": "ios"},
    {"idiom": "ios-marketing", "size": "1024x768", "scale": "1x", "platform": "ios"},
]

# One pack, and iOS is what says so: an app may embed exactly one
# `com.apple.message-payload-provider` extension. A second one installs as
# "Multiple message payload provider extensions found in app but only one is
# allowed" — from `installd`, at install time, long after a green build.
#
# The `.stickerpack` folder name is an identifier, not a label — what a reader sees in
# the Messages drawer is the extension's CFBundleDisplayName. Keeping it space-free
# keeps every shell command that touches these paths honest.
#
# `animated` is the switch worth knowing about. Every character exists both ways and
# both fit the byte limit at this size, so a pack of all thirty-two is a small edit
# away — it was left at sixteen because an animated sticker at rest reads exactly like
# its still, and a drawer holding both is the same sixteen characters twice.
PACKS = [
    {
        "target": "ReachyStickers",
        "pack": "ReachyMini",
        "icon_character": "astronaut",
        "animated": True,
    },
]

INFO = {"author": "reachy-mini-swift", "version": 1}


def write_json(path: Path, payload: dict) -> None:
    """Sorted keys and a trailing newline, so a second run leaves the tree clean."""
    path.write_text(json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def require_ffmpeg() -> str:
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        sys.exit(
            "ffmpeg is not on PATH. It is deliberately not pinned in mise.toml — this "
            "script runs by hand when the art changes and its output is committed.\n"
            "Install it with: brew install ffmpeg"
        )
    return ffmpeg


def decode_frames(ffmpeg: str, source: Path, fps: int, size: int) -> list[Image.Image]:
    """Decodes a VP9-with-alpha WebM into RGBA frames.

    The alpha rides in a side channel that ffprobe reports as `alpha_mode: 1` while
    calling the stream `yuv420p`, which reads like there is no transparency at all.
    There is; asking for `rgba` output gets it.
    """
    raw = subprocess.run(
        [
            ffmpeg, "-v", "error", "-c:v", "libvpx-vp9", "-i", str(source),
            "-vf", f"fps={fps},scale={size}:{size}:flags=lanczos",
            "-pix_fmt", "rgba", "-f", "rawvideo", "-",
        ],
        capture_output=True,
        check=True,
    ).stdout
    stride = size * size * 4
    return [
        Image.frombytes("RGBA", (size, size), raw[offset:offset + stride])
        for offset in range(0, len(raw), stride)
    ]


def encode_apng(frames: list[Image.Image], fps: int, colors: int) -> bytes:
    """Writes one shared-palette APNG.

    Pillow's `quantize` refuses an externally supplied palette for an RGBA image, so
    the frames are stacked, quantised as a single picture, and sliced apart. That is
    what leaves every frame indexing the same table — which an APNG requires, since
    the frames after the first carry no palette of their own.
    """
    width, height = frames[0].size
    montage = Image.new("RGBA", (width, height * len(frames)))
    for index, frame in enumerate(frames):
        montage.paste(frame, (0, height * index))
    quantised = montage.quantize(colors=colors, method=Image.FASTOCTREE, dither=Image.NONE)
    sliced = [
        quantised.crop((0, height * index, width, height * (index + 1)))
        for index in range(len(frames))
    ]
    buffer = io.BytesIO()
    sliced[0].save(
        buffer,
        format="PNG",
        save_all=True,
        append_images=sliced[1:],
        duration=round(1000 / fps),
        loop=0,
        optimize=True,
    )
    return buffer.getvalue()


def build_animated(ffmpeg: str, source: Path, name: str) -> tuple[bytes, int, int]:
    """Walks the ladder until a rung fits under Apple's limit."""
    best = None
    for fps, colors in BUDGET_LADDER:
        payload = encode_apng(decode_frames(ffmpeg, source, fps, STICKER_PX), fps, colors)
        if best is None or len(payload) < best[0]:
            best = (len(payload), fps, colors)
        if len(payload) <= MAX_STICKER_BYTES:
            return payload, fps, colors
    size, fps, colors = best
    sys.exit(
        f"{name}: no rung of BUDGET_LADDER fits under {MAX_STICKER_BYTES} bytes — the "
        f"smallest was {size} bytes at {fps} fps / {colors} colours. Either add a "
        f"lower rung or shorten the animation."
    )


def build_still(source: Path) -> bytes:
    image = Image.open(source).convert("RGBA").resize((STICKER_PX, STICKER_PX), Image.LANCZOS)
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


def blend(hex_value: int, toward: float) -> tuple[int, int, int]:
    """Blends a palette constant toward white (positive) or black (negative).

    A blend rather than an addition, for the reason `ReachyTheme.blend` gives: a
    channel already at full lightens without dragging the hue after it.
    """
    target = 1.0 if toward > 0 else 0.0
    weight = abs(toward)
    return tuple(
        round((value + (target - value) * weight) * 255)
        for value in (((hex_value >> shift) & 0xFF) / 255 for shift in (16, 8, 0))
    )


def rgb(hex_value: int) -> tuple[int, int, int]:
    return ((hex_value >> 16) & 0xFF, (hex_value >> 8) & 0xFF, hex_value & 0xFF)


def render_icon(character: Path, width: int, height: int) -> Image.Image:
    """The four-stop vertical gradient of `ReachyTheme.iconSwatch`, with a face on it."""
    stops = [
        (0.0, blend(GRADIENT_TOP, SWATCH_HIGHLIGHT)),
        (SWATCH_STOP_INSET, rgb(GRADIENT_TOP)),
        (1 - SWATCH_STOP_INSET, rgb(GRADIENT_BOTTOM)),
        (1.0, blend(GRADIENT_BOTTOM, SWATCH_SHADE)),
    ]
    # Drawn one pixel wide and stretched, which is both faster than filling every
    # pixel and exactly what a vertical gradient means.
    column = Image.new("RGBA", (1, height))
    strip = column.load()
    for y in range(height):
        position = y / max(1, height - 1)
        lower = max(i for i, (stop, _) in enumerate(stops) if stop <= position or i == 0)
        upper = min(lower + 1, len(stops) - 1)
        span = stops[upper][0] - stops[lower][0]
        t = 0.0 if span == 0 else (position - stops[lower][0]) / span
        strip[0, y] = tuple(
            round(stops[lower][1][c] + (stops[upper][1][c] - stops[lower][1][c]) * t)
            for c in range(3)
        ) + (255,)
    canvas = column.resize((width, height), Image.NEAREST)

    # 78 % of the short side: the antennas need headroom, and the icon is masked to a
    # rounded rect by the system rather than by us.
    side = round(min(width, height) * 0.78)
    face = Image.open(character).convert("RGBA").resize((side, side), Image.LANCZOS)
    canvas.alpha_composite(face, ((width - side) // 2, (height - side) // 2))
    return canvas


def write_icon_set(directory: Path, character: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    images = []
    for slot in ICON_SLOTS:
        points_wide, points_high = (float(v) for v in slot["size"].split("x"))
        scale = int(slot["scale"].rstrip("x"))
        width, height = round(points_wide * scale), round(points_high * scale)
        filename = f"icon-{slot['idiom']}-{slot['size']}@{slot['scale']}.png"
        render_icon(character, width, height).convert("RGB").save(
            directory / filename, format="PNG", optimize=True
        )
        images.append({**slot, "filename": filename})
    write_json(directory / "Contents.json", {"images": images, "info": INFO})


def main() -> None:
    ffmpeg = require_ffmpeg()
    for spec in PACKS:
        catalogue = ROOT / "Apps" / spec["target"] / "Resources" / "Stickers.xcassets"
        if catalogue.exists():
            shutil.rmtree(catalogue)
        pack = catalogue / f"{spec['pack']}.stickerpack"
        pack.mkdir(parents=True)
        write_json(catalogue / "Contents.json", {"info": INFO})
        write_json(pack / "Contents.json", {"info": INFO, "properties": {"grid-size": GRID_SIZE}})

        for name, _emoji, still, animation, described, motion in CHARACTERS:
            sticker = pack / f"{name}.sticker"
            sticker.mkdir()
            if spec["animated"]:
                payload, fps, colors = build_animated(ffmpeg, ART / "animated" / animation, name)
                filename = f"{name}.apng"
                label = f"{described}, {motion}"
                note = f"{len(payload) / 1024:6.1f} KB  {fps} fps  {colors} colours"
            else:
                payload = build_still(ART / still)
                filename = f"{name}.png"
                label = described
                note = f"{len(payload) / 1024:6.1f} KB"
            if len(payload) > MAX_STICKER_BYTES:
                sys.exit(f"{name}: {len(payload)} bytes is over Apple's {MAX_STICKER_BYTES}")
            (sticker / filename).write_bytes(payload)
            write_json(
                sticker / "Contents.json",
                {"info": INFO, "properties": {"filename": filename, "accessibility-label": label}},
            )
            print(f"  {spec['target']:20} {name:14} {note}")

        write_icon_set(
            catalogue / "iMessage App Icon.stickersiconset",
            ART / f"{spec['icon_character']}.png",
        )
        print(f"  {spec['target']:20} icon set")


if __name__ == "__main__":
    main()
