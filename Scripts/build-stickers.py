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

**The frame count is per file, and the frames are not evenly spaced.** A loop holds
at most every second frame of the 30 fps source, and some loops do not fit that many
under the limit. Each sticker starts at that maximum and drops one frame at a time
until the file fits; the script fails rather than ship a file Apple will reject at
upload. The frames it keeps are chosen by motion — a fast stretch gets more of them, a
hold gets fewer — and each frame carries its exact delay, a whole number of source
frames. So every sticker plays at the source's own speed, whatever its frame count.

Usage: `mise run stickers:build`. Needs ffmpeg on PATH (deliberately not pinned —
this runs by hand when the art changes, and its output is committed).
"""

from __future__ import annotations

import io
import json
import shutil
import struct
import subprocess
import sys
import zlib
from pathlib import Path

from PIL import Image, ImageChops, ImageFilter, ImageStat

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / "art" / "stickers"

# Apple's ceiling, and the one number this whole script is arranged around. Apple
# writes "500 KB" and does not say which kilobyte; 500 000 bytes is the stricter
# reading, and App Store Connect gives its verdict only at upload.
MAX_STICKER_BYTES = 500_000

# `grid-size` is a pack-level property, so both packs commit to one size. Regular is
# 408 px at @3x: a clean downscale from the 512 px source rather than an upscale, and
# the largest of the three that leaves the animations room under the byte limit.
GRID_SIZE = "regular"
STICKER_PX = 408

# `animate.py` renders every loop at 30 fps, and every delay in an APNG here is a
# whole number of those source frames.
SOURCE_FPS = 30

# The shortest delay is two source frames, 67 ms. One source frame would be 33 ms, and
# ImageIO raises an APNG delay under 50 ms to 50 ms (measured: 33.3 ms reads back as
# 50) — so that frame would play slow and the motion would lose its timing. This floor
# also sets the largest step a fast motion can get: two source frames of it.
MIN_GAP = 2
# The longest is six source frames, 200 ms. A longer one would let a slow drift stand
# still and then jump; at this length only a hold gets it.
MAX_GAP = 6

# The fewest frames a two-second loop may keep. Below this the script fails instead.
MIN_FRAMES = 15

# A full palette at every frame count. Colour is the last thing to give up: on artwork
# this smooth a flattened palette shows more than a dropped frame.
COLOURS = 256

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


def decode_frames(ffmpeg: str, source: Path, size: int) -> list[Image.Image]:
    """Decodes every frame of a VP9-with-alpha WebM into RGBA, in order.

    The alpha rides in a side channel that ffprobe reports as `alpha_mode: 1` while
    calling the stream `yuv420p`, which reads like there is no transparency at all.
    There is; asking for `rgba` output gets it.

    There is deliberately no `fps` filter. These WebMs carry a 1/1000 time base, and
    over it `fps=15` keeps source frames 1, 2, 4, 7, 8, 10, 13 … instead of every
    second one, so the motion runs at 0.5×, 1× and 1.5× speed in turn, five times a
    second. `-fps_mode passthrough` gives each decoded frame once, and
    `pick_frames` chooses which ones to keep.
    """
    raw = subprocess.run(
        [
            ffmpeg, "-v", "error", "-c:v", "libvpx-vp9", "-i", str(source),
            "-fps_mode", "passthrough", "-vf", f"scale={size}:{size}:flags=lanczos",
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


def motion_steps(frames: list[Image.Image]) -> list[float]:
    """How far the outline moves from each source frame to the next, in pixels.

    The alpha that changed, divided by the length of the outline: a shift by d pixels
    uncovers about d pixels of area for each pixel of outline, so the ratio reads as a
    mean displacement for a shift, a turn and a squash alike. The outline and not the
    colours, because each character moves as rigid layers, so its outline carries all
    of the motion. Against the analytic motion of the presets in `animate.py` it
    correlates at 0.86 to 1.00 (measured on all sixteen). The last step wraps around to
    the first frame: the loop has a seam, and the seam is a step like any other.
    """
    alphas = [frame.getchannel("A") for frame in frames]
    steps = []
    for current, following in zip(alphas, alphas[1:] + alphas[:1]):
        changed = ImageStat.Stat(ImageChops.difference(current, following)).sum[0] / 255
        solid = current.point(lambda value: 255 if value > 127 else 0)
        outline = ImageChops.subtract(solid, solid.filter(ImageFilter.MinFilter(3)))
        length = ImageStat.Stat(outline).sum[0] / 255
        steps.append(changed / max(length, 1.0))
    return steps


def pick_frames(steps: list[float], count: int) -> list[int]:
    """Chooses `count` source frames so that each displayed step moves about as far.

    Each kept frame holds until the next one, for MIN_GAP to MAX_GAP source frames. Of
    all such choices this takes the one with the smallest sum of each step's motion to
    the fourth power: close to the smallest largest step, but it still spends every
    frame where the motion is. Source frame 0 is always kept, so the first frame of the
    file — the one a decoder without APNG support shows — is the pose the loop starts
    from.
    """
    total = len(steps)
    prefix = [0.0]
    for step in steps:
        prefix.append(prefix[-1] + step)
    unreachable = float("inf")
    # cost[k][j]: the best sum for k kept frames that cover source frames 0 ..< j.
    cost = [[unreachable] * (total + 1) for _ in range(count + 1)]
    previous = [[0] * (total + 1) for _ in range(count + 1)]
    cost[0][0] = 0.0
    for kept in range(1, count + 1):
        for end in range(kept * MIN_GAP, total + 1):
            for gap in range(MIN_GAP, MAX_GAP + 1):
                start = end - gap
                if start < 0 or cost[kept - 1][start] == unreachable:
                    continue
                candidate = cost[kept - 1][start] + (prefix[end] - prefix[start]) ** 4
                if candidate < cost[kept][end]:
                    cost[kept][end] = candidate
                    previous[kept][end] = start
    if cost[count][total] == unreachable:
        raise ValueError(f"{count} frames cannot cover {total} with gaps {MIN_GAP}-{MAX_GAP}")
    picked, end = [], total
    for kept in range(count, 0, -1):
        end = previous[kept][end]
        picked.append(end)
    return picked[::-1]


def quantise(frames: list[Image.Image]) -> tuple[list[Image.Image], list[int]]:
    """Gives the frames one shared palette: the frames as indices, and the RGBA table.

    Pillow's `quantize` refuses an externally supplied palette for an RGBA image, so
    the frames are stacked, quantised as a single picture, and sliced apart. That is
    what leaves every frame indexing the same table — which an APNG requires, since
    the frames after the first carry no palette of their own.
    """
    width, height = frames[0].size
    montage = Image.new("RGBA", (width, height * len(frames)))
    for index, frame in enumerate(frames):
        montage.paste(frame, (0, height * index))
    quantised = montage.quantize(colors=COLOURS, method=Image.FASTOCTREE, dither=Image.NONE)
    used = quantised.getextrema()[1] + 1
    # The indices as a greyscale image, which ImageChops can compare.
    indices = Image.frombytes("L", quantised.size, quantised.tobytes())
    sliced = [
        indices.crop((0, height * index, width, height * (index + 1)))
        for index in range(len(frames))
    ]
    return sliced, quantised.getpalette("RGBA")[:used * 4]


def merge_repeats(
    frames: list[Image.Image], delays: list[int]
) -> tuple[list[Image.Image], list[int]]:
    """A frame equal to the one before it adds its delay to that frame instead."""
    kept, held = [frames[0]], [delays[0]]
    for frame, delay in zip(frames[1:], delays[1:]):
        if ImageChops.difference(frame, kept[-1]).getbbox() is None:
            held[-1] += delay
        else:
            kept.append(frame)
            held.append(delay)
    return kept, held


def png_chunk(kind: bytes, body: bytes) -> bytes:
    checksum = zlib.crc32(kind + body)
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", checksum)


def write_apng(frames: list[Image.Image], palette: list[int], delays: list[int]) -> bytes:
    """Writes an APNG that loops for ever, each frame with its exact delay.

    The chunks are written here and not by Pillow, because Pillow writes a delay in
    whole milliseconds, and two source frames are 66.7 ms, not 67. Each `fcTL` here
    holds its delay as a fraction — source frames over SOURCE_FPS — so the loop is
    exactly as long as its source. A frame after the first stores only the rectangle
    that changed, drawn over the frame before it, as Pillow's own encoder does.

    Deflate is zlib at level 9. Zopfli was measured: about 6.5 % smaller, which fits one
    to three more frames into the seven files under 30 frames, but leaves the largest
    step of each one unchanged — MIN_GAP sets that. Its search took 131 s for those
    seven files alone, against 28 s for this whole script.
    """
    width, height = frames[0].size
    colours = bytes(value for index, value in enumerate(palette) if index % 4 != 3)
    chunks = [
        b"\x89PNG\r\n\x1a\n",
        png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 3, 0, 0, 0)),
        # Zero plays: loop for ever.
        png_chunk(b"acTL", struct.pack(">II", len(frames), 0)),
        png_chunk(b"PLTE", colours),
        png_chunk(b"tRNS", bytes(palette[3::4])),
    ]
    sequence = 0
    before = None
    for frame, delay in zip(frames, delays):
        if before is None:
            box = (0, 0, width, height)
        else:
            box = ImageChops.difference(frame, before).getbbox()
        left, top, right, bottom = box
        span = right - left
        rows = frame.crop(box).tobytes()
        # Filter type 0 on every row: the PNG spec's advice for palette data.
        data = zlib.compress(
            b"".join(b"\x00" + rows[row * span:(row + 1) * span] for row in range(bottom - top)),
            9,
        )
        # Dispose op 0 keeps the frame for the next one to draw over; blend op 0 replaces
        # the rectangle, transparent pixels included.
        chunks.append(png_chunk(b"fcTL", struct.pack(
            ">IIIIIHHBB", sequence, span, bottom - top, left, top, delay, SOURCE_FPS, 0, 0
        )))
        sequence += 1
        if before is None:
            chunks.append(png_chunk(b"IDAT", data))
        else:
            chunks.append(png_chunk(b"fdAT", struct.pack(">I", sequence) + data))
            sequence += 1
        before = frame
    chunks.append(png_chunk(b"IEND", b""))
    return b"".join(chunks)


def check_apng(
    payload: bytes, frames: list[Image.Image], palette: list[int], delays: list[int]
) -> None:
    """Reads the file back with Pillow's APNG decoder, because the writer above is ours."""
    image = Image.open(io.BytesIO(payload))
    if image.n_frames != len(frames) or image.info.get("loop") != 0:
        sys.exit(f"APNG reads back as {image.n_frames} frames, loop {image.info.get('loop')}")
    for index, (frame, delay) in enumerate(zip(frames, delays)):
        image.seek(index)
        if abs(image.info["duration"] - 1000 * delay / SOURCE_FPS) > 0.01:
            sys.exit(f"APNG frame {index} reads back as {image.info['duration']} ms")
        written = Image.frombytes("P", frame.size, frame.tobytes())
        written.putpalette(palette, "RGBA")
        changed = ImageChops.difference(image.convert("RGBA"), written.convert("RGBA"))
        if changed.getbbox() is not None:
            sys.exit(f"APNG frame {index} reads back with other pixels than were written")


def build_animated(ffmpeg: str, source: Path, name: str) -> tuple[bytes, list[int]]:
    """Drops one frame at a time from every second source frame until the file fits."""
    frames = decode_frames(ffmpeg, source, STICKER_PX)
    steps = motion_steps(frames)
    smallest = None
    for count in range(len(frames) // MIN_GAP, MIN_FRAMES - 1, -1):
        picked = pick_frames(steps, count)
        delays = [
            following - current
            for current, following in zip(picked, picked[1:] + [len(frames)])
        ]
        indexed, palette = quantise([frames[index] for index in picked])
        indexed, delays = merge_repeats(indexed, delays)
        payload = write_apng(indexed, palette, delays)
        if smallest is None or len(payload) < smallest[0]:
            smallest = (len(payload), count)
        if len(payload) <= MAX_STICKER_BYTES:
            check_apng(payload, indexed, palette, delays)
            return payload, delays
    size, count = smallest
    sys.exit(
        f"{name}: no frame count down to {MIN_FRAMES} fits under {MAX_STICKER_BYTES} "
        f"bytes — the smallest was {size} bytes at {count} frames. Lower MIN_FRAMES or "
        f"shorten the animation."
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
                payload, delays = build_animated(ffmpeg, ART / "animated" / animation, name)
                # `.png`, not `.apng`, and the difference is a rejected upload rather than taste.
                # An APNG *is* a PNG — same signature, with acTL/fcTL/fdAT as ancillary chunks a
                # plain decoder skips — but App Store Connect validates the sticker's extension
                # against `jpg, jpeg, gif, png` and rejects `apng` for every file in the pack.
                # Xcode, actool and Messages all accept the animation under a `.png` name.
                filename = f"{name}.png"
                label = f"{described}, {motion}"
                note = (
                    f"{len(payload):7d} B  {len(delays):2d} frames  "
                    f"delays {min(delays)}-{max(delays)}/{SOURCE_FPS} s"
                )
            else:
                payload = build_still(ART / still)
                filename = f"{name}.png"
                label = described
                note = f"{len(payload):7d} B"
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
