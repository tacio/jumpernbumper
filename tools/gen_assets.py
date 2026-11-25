#!/usr/bin/env python3
"""Deterministic procedural pixel-art, retro SFX, and shared data sync generator.

Generates all Phase 3 visual and audio assets into `client/assets/` and syncs
`shared/*.json` -> `client/data/*.json` byte-for-byte so Godot exports bundle
the exact canonical map, physics constants, and table schemas.

Dependencies: Python 3.12+, pillow, numpy, and stdlib (json, pathlib, wave).
Zero Node.js or JavaScript.
"""

from __future__ import annotations

import pathlib
import wave
from typing import Dict, List, Tuple

import numpy as np
from PIL import Image

ROOT_DIR = pathlib.Path(__file__).resolve().parent.parent
SHARED_DIR = ROOT_DIR / "shared"
CLIENT_DIR = ROOT_DIR / "client"
CLIENT_DATA_DIR = CLIENT_DIR / "data"
SPRITES_DIR = CLIENT_DIR / "assets" / "sprites"
TILES_DIR = CLIENT_DIR / "assets" / "tiles"
BG_DIR = CLIENT_DIR / "assets" / "bg"
SFX_DIR = CLIENT_DIR / "assets" / "sfx"

SAMPLE_RATE = 22050
SEED = 42

RGBA = Tuple[int, int, int, int]

# ---------------------------------------------------------------------------
# 1. Shared JSON Sync
# ---------------------------------------------------------------------------


def sync_shared_json() -> List[pathlib.Path]:
    """Mirror `shared/*.json` into `client/data/*.json` byte-for-byte."""
    CLIENT_DATA_DIR.mkdir(parents=True, exist_ok=True)
    shared_files = sorted(SHARED_DIR.glob("*.json"))
    expected_names = {p.name for p in shared_files}

    for existing in CLIENT_DATA_DIR.glob("*.json"):
        if existing.name not in expected_names:
            existing.unlink()

    synced: List[pathlib.Path] = []
    for src in shared_files:
        dst = CLIENT_DATA_DIR / src.name
        dst.write_bytes(src.read_bytes())
        synced.append(dst)
    return synced


# ---------------------------------------------------------------------------
# 2. Bunny Sprite Sheet (128x64: 8 frames x 4 bunnies @ 16x16)
# ---------------------------------------------------------------------------

# Legend:
# . = transparent
# O = dark outline
# B = base fur
# H = highlight fur
# S = shadow fur
# C = cream belly / tail / paw pad
# E = inner ear / pink nose
# W = eye sclera / highlight
# P = eye pupil
BUNNY_FRAMES: List[List[str]] = [
    # Frame 0: idle1 (alert upright, feet at row 15)
    [
        "....OO..OO......",
        "...OHEOOHEO.....",
        "...OHBOOHBO.....",
        "...OHBOOHBO.....",
        "...OBBOOBBO.....",
        "...OOHHHHHO.....",
        "..OHBBBBBBBO....",
        "..OHBBBBBWPBO...",
        "..OBBBBBBWPEO...",
        "...OBBBBBBBO....",
        "..OOBBCCCBO.....",
        ".OCOBBCCCBBO....",
        ".OOOBSSCCBSO....",
        "...OSSSSSSSO....",
        "...OBBO.OBBO....",
        "...OOOO.OOOO....",
    ],
    # Frame 1: idle2 (1px gentle bob + subtle blink/ear dip)
    [
        "................",
        "....OO..OO......",
        "...OHEOOHEO.....",
        "...OHBOOHBO.....",
        "...OBBOOBBO.....",
        "...OOHHHHHO.....",
        "..OHBBBBBBBO....",
        "..OHBBBBBWBO....",
        "..OBBBBBBPPEO...",
        "...OBBBBBBBO....",
        ".OOOBBCCCBO.....",
        "OCCOBBCCCBBO....",
        ".OOOBSSCCBSO....",
        "...OSSSSSSSO....",
        "...OBBO.OBBO....",
        "...OOOO.OOOO....",
    ],
    # Frame 2: run1 (forward stride, front leg forward, back leg back)
    [
        "................",
        "..OO..OO........",
        ".OHEOOHEO.......",
        "..OHBOOHBO......",
        "...OBBOOBBO.....",
        "....OOHHHHHO....",
        "...OHBBBBBBBO...",
        "...OHBBBBBWPBO..",
        "...OBBBBBBWPEO..",
        "....OBBBBBBBO...",
        "..OOBBCCCBOO....",
        ".OCOBBCCCBBO....",
        ".OOOBSSCCBSO....",
        "...OSSSSSSSO....",
        "..OBBO..OBBO....",
        "..OOOO...OOOO...",
    ],
    # Frame 3: run2 (tucked squash mid-stride)
    [
        "................",
        "................",
        "..OO..OO........",
        ".OHEOOHEO.......",
        "..OHBOOHBO......",
        "...OOHHHHHO.....",
        "..OHBBBBBBBO....",
        "..OHBBBBBWPBO...",
        "..OBBBBBBWPEO...",
        "...OBBBBBBBO....",
        ".OOOBBCCCBOO....",
        "OCCOBBCCCBBO....",
        ".OOOBSSCCBSO....",
        "...OSSSSSSSO....",
        "....OBBOOBBO....",
        "....OOOOOOOO....",
    ],
    # Frame 4: run3 (extended push-off)
    [
        "....OO..OO......",
        "...OHEOOHEO.....",
        "...OHBOOHBO.....",
        "....OBBOOBBO....",
        "....OOHHHHHO....",
        "...OHBBBBBBBO...",
        "...OHBBBBBWPBO..",
        "...OBBBBBBWPEO..",
        "....OBBBBBBBO...",
        "..OOBBCCCBOO....",
        ".OCOBBCCCBBO....",
        ".OOOBSSCCBSO....",
        "...OSSSSSSSO....",
        "..OBSO...OBBO...",
        ".OBBO.....OBBO..",
        ".OOOO.....OOOO..",
    ],
    # Frame 5: jump (stretched upward)
    [
        "...OO..OO.......",
        "..OHEOOHEO......",
        "..OHBOOHBO......",
        "...OBBOOBBO.....",
        "...OOHHHHHO.....",
        "..OHBBBBBBBO....",
        "..OHBBBBBWPBO...",
        "..OBBBBBBWPEO...",
        "...OBBBBBBBO....",
        "..OOBBCCCBOO....",
        ".OCOBBCCCBBO....",
        ".OOOBSSCCBSO....",
        "...OSSSSSSSO....",
        "...OBBO..OBBO...",
        "...OOOO...OOOO..",
        "................",
    ],
    # Frame 6: fall (ears up, paws splayed downward)
    [
        "..OO....OO......",
        ".OHEO..OHEO.....",
        "..OHBO.OHBO.....",
        "...OBBOOBBO.....",
        "...OOHHHHHO.....",
        "..OHBBBBBBBO....",
        "..OHBBBBBWPBO...",
        "..OBBBBBBWPEO...",
        "...OBBBBBBBO....",
        "..OOBBCCCBOO....",
        ".OCOBBCCCBBO....",
        ".OOOBSSCCBSO....",
        "...OSSSSSSSO....",
        "..OBBO..OBBO....",
        "..OOOO..OOOO....",
        "................",
    ],
    # Frame 7: swim (horizontal paddling pose)
    [
        "................",
        "................",
        "..OO..OO........",
        ".OHEOOHEO.......",
        "..OHBOOHBO......",
        "...OOHHHHHO.....",
        "..OHBBBBBBBO....",
        "..OHBBBBBWPBO...",
        "..OBBBBBBWPEO...",
        ".OOOBBBBBBBO....",
        "OCCOBBCCCCBBO...",
        ".OOOBSSCCBSOO...",
        "..OBBSSSSSSBO...",
        "..OOOO..OOOO....",
        "................",
        "................",
    ],
]

BUNNY_PALETTES: List[Tuple[str, Dict[str, RGBA]]] = [
    (
        "Dott",
        {
            "O": (24, 16, 22, 255),
            "B": (148, 92, 52, 255),
            "H": (188, 126, 78, 255),
            "S": (102, 58, 34, 255),
            "C": (244, 224, 190, 255),
            "E": (228, 138, 148, 255),
            "W": (255, 255, 255, 255),
            "P": (20, 14, 24, 255),
        },
    ),
    (
        "Jiffy",
        {
            "O": (28, 20, 14, 255),
            "B": (232, 178, 42, 255),
            "H": (252, 218, 92, 255),
            "S": (182, 124, 24, 255),
            "C": (252, 244, 206, 255),
            "E": (238, 138, 128, 255),
            "W": (255, 255, 255, 255),
            "P": (24, 18, 18, 255),
        },
    ),
    (
        "Fizz",
        {
            "O": (28, 26, 38, 255),
            "B": (238, 236, 244, 255),
            "H": (255, 255, 255, 255),
            "S": (184, 188, 206, 255),
            "C": (255, 248, 242, 255),
            "E": (244, 148, 170, 255),
            "W": (255, 255, 255, 255),
            "P": (26, 22, 38, 255),
        },
    ),
    (
        "Mijji",
        {
            "O": (18, 22, 34, 255),
            "B": (92, 126, 178, 255),
            "H": (134, 170, 218, 255),
            "S": (58, 84, 128, 255),
            "C": (214, 228, 244, 255),
            "E": (232, 148, 178, 255),
            "W": (255, 255, 255, 255),
            "P": (18, 20, 32, 255),
        },
    ),
]


def _render_ascii_sprite(
    rows: List[str], palette: Dict[str, RGBA], width: int, height: int
) -> Image.Image:
    assert len(rows) == height, f"Expected {height} rows, got {len(rows)}"
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    px = img.load()
    for y, line in enumerate(rows):
        assert len(line) == width, f"Row {y} expected width {width}, got {len(line)}"
        for x, ch in enumerate(line):
            if ch != ".":
                px[x, y] = palette[ch]
    return img


def generate_bunny_sheet() -> pathlib.Path:
    """Generate `client/assets/sprites/bunny_sheet.png` (128x64, 4x8 @ 16x16)."""
    SPRITES_DIR.mkdir(parents=True, exist_ok=True)
    sheet = Image.new("RGBA", (128, 64), (0, 0, 0, 0))
    for row_idx, (_name, palette) in enumerate(BUNNY_PALETTES):
        for col_idx, frame_rows in enumerate(BUNNY_FRAMES):
            sprite = _render_ascii_sprite(frame_rows, palette, 16, 16)
            sheet.paste(sprite, (col_idx * 16, row_idx * 16))
    out_path = SPRITES_DIR / "bunny_sheet.png"
    sheet.save(out_path)
    return out_path


# Robot bunny frames (16x16): antenna on top, glowing visor, riveted steel chest.
# Additional palette keys:
# A = antenna tip / LED glow
# V = dark visor frame
# L = glowing LED eye
# M = brushed steel chest / mechanical trim
ROBOT_BUNNY_FRAMES: List[List[str]] = [
    # Frame 0: idle1
    [
        "....OO..OO..AO..",
        "...OMEOOMEO.O...",
        "...OHBOOHBO.O...",
        "...OHBOOHBO.....",
        "...OBBOOBBO.....",
        "...OOHHHHHO.....",
        "..OHBBBBBBBO....",
        "..OHBBBBVVLLO...",
        "..OBBBBBVVVVO...",
        "...OBBBBBBBO....",
        "..OOBBMMMBO.....",
        ".OMOBBMMMBBO....",
        ".OOOBSSMMBSO....",
        "...OSSSSSSSO....",
        "...OBBO.OBBO....",
        "...OOOO.OOOO....",
    ],
    # Frame 1: idle2 (antenna blink + 1px bob)
    [
        "............OO..",
        "....OO..OO..O...",
        "...OMEOOMEO.....",
        "...OHBOOHBO.....",
        "...OBBOOBBO.....",
        "...OOHHHHHO.....",
        "..OHBBBBBBBO....",
        "..OHBBBBVVVVO...",
        "..OBBBBBVVLLO...",
        "...OBBBBBBBO....",
        ".OOOBBMMMBO.....",
        "OMMOBBMMMBBO....",
        ".OOOBSSMMBSO....",
        "...OSSSSSSSO....",
        "...OBBO.OBBO....",
        "...OOOO.OOOO....",
    ],
    # Frame 2: run1
    [
        "............AO..",
        "..OO..OO....O...",
        ".OMEOOMEO.......",
        "..OHBOOHBO......",
        "...OBBOOBBO.....",
        "....OOHHHHHO....",
        "...OHBBBBBBBO...",
        "...OHBBBBVVLLO..",
        "...OBBBBBVVVVO..",
        "....OBBBBBBBO...",
        "..OOBBMMMBOO....",
        ".OMOBBMMMBBO....",
        ".OOOBSSMMBSO....",
        "...OSSSSSSSO....",
        "..OBBO..OBBO....",
        "..OOOO...OOOO...",
    ],
    # Frame 3: run2
    [
        "................",
        "............AO..",
        "..OO..OO....O...",
        ".OMEOOMEO.......",
        "..OHBOOHBO......",
        "...OOHHHHHO.....",
        "..OHBBBBBBBO....",
        "..OHBBBBVVLLO...",
        "..OBBBBBVVVVO...",
        "...OBBBBBBBO....",
        ".OOOBBMMMBOO....",
        "OMMOBBMMMBBO....",
        ".OOOBSSMMBSO....",
        "...OSSSSSSSO....",
        "....OBBOOBBO....",
        "....OOOOOOOO....",
    ],
    # Frame 4: run3
    [
        "....OO..OO..AO..",
        "...OMEOOMEO.O...",
        "...OHBOOHBO.....",
        "....OBBOOBBO....",
        "....OOHHHHHO....",
        "...OHBBBBBBBO...",
        "...OHBBBBVVLLO..",
        "...OBBBBBVVVVO..",
        "....OBBBBBBBO...",
        "..OOBBMMMBOO....",
        ".OMOBBMMMBBO....",
        ".OOOBSSMMBSO....",
        "...OSSSSSSSO....",
        "..OBSO...OBBO...",
        ".OBBO.....OBBO..",
        ".OOOO.....OOOO..",
    ],
    # Frame 5: jump
    [
        "...OO..OO...AO..",
        "..OMEOOMEO..O...",
        "..OHBOOHBO......",
        "...OBBOOBBO.....",
        "...OOHHHHHO.....",
        "..OHBBBBBBBO....",
        "..OHBBBBVVLLO...",
        "..OBBBBBVVVVO...",
        "...OBBBBBBBO....",
        "..OOBBMMMBOO....",
        ".OMOBBMMMBBO....",
        ".OOOBSSMMBSO....",
        "...OSSSSSSSO....",
        "...OBBO..OBBO...",
        "...OOOO...OOOO..",
        "................",
    ],
    # Frame 6: fall
    [
        "..OO....OO..AO..",
        ".OMEO..OMEO.O...",
        "..OHBO.OHBO.....",
        "...OBBOOBBO.....",
        "...OOHHHHHO.....",
        "..OHBBBBBBBO....",
        "..OHBBBBVVLLO...",
        "..OBBBBBVVVVO...",
        "...OBBBBBBBO....",
        "..OOBBMMMBOO....",
        ".OMOBBMMMBBO....",
        ".OOOBSSMMBSO....",
        "...OSSSSSSSO....",
        "..OBBO..OBBO....",
        "..OOOO..OOOO....",
        "................",
    ],
    # Frame 7: swim
    [
        "................",
        "............AO..",
        "..OO..OO....O...",
        ".OMEOOMEO.......",
        "..OHBOOHBO......",
        "...OOHHHHHO.....",
        "..OHBBBBBBBO....",
        "..OHBBBBVVLLO...",
        "..OBBBBBVVVVO...",
        ".OOOBBBBBBBO....",
        "OMMOBBMMMMBBO...",
        ".OOOBSSMMBSOO...",
        "..OBBSSSSSSBO...",
        "..OOOO..OOOO....",
        "................",
        "................",
    ],
]

ROBOT_PALETTES: List[Tuple[str, Dict[str, RGBA]]] = [
    (
        "Robo-Dott",
        {
            "O": (20, 22, 28, 255),
            "B": (146, 102, 72, 255),
            "H": (196, 152, 118, 255),
            "S": (92, 62, 46, 255),
            "M": (176, 184, 198, 255),
            "E": (96, 220, 255, 255),
            "V": (24, 30, 44, 255),
            "L": (255, 92, 92, 255),
            "A": (255, 92, 92, 255),
        },
    ),
    (
        "Robo-Jiffy",
        {
            "O": (22, 22, 26, 255),
            "B": (212, 168, 56, 255),
            "H": (246, 214, 112, 255),
            "S": (152, 110, 32, 255),
            "M": (188, 194, 206, 255),
            "E": (96, 220, 255, 255),
            "V": (24, 30, 44, 255),
            "L": (92, 255, 160, 255),
            "A": (92, 255, 160, 255),
        },
    ),
    (
        "Robo-Fizz",
        {
            "O": (22, 24, 34, 255),
            "B": (196, 204, 218, 255),
            "H": (240, 244, 252, 255),
            "S": (132, 142, 164, 255),
            "M": (162, 174, 194, 255),
            "E": (96, 220, 255, 255),
            "V": (24, 30, 44, 255),
            "L": (88, 228, 255, 255),
            "A": (88, 228, 255, 255),
        },
    ),
    (
        "Robo-Mijji",
        {
            "O": (16, 20, 32, 255),
            "B": (88, 128, 184, 255),
            "H": (138, 178, 228, 255),
            "S": (54, 82, 128, 255),
            "M": (176, 186, 204, 255),
            "E": (255, 196, 72, 255),
            "V": (20, 26, 40, 255),
            "L": (255, 196, 72, 255),
            "A": (255, 196, 72, 255),
        },
    ),
]


def generate_robot_bunny_sheet() -> pathlib.Path:
    """Generate `client/assets/sprites/robot_bunny_sheet.png` (128x64, 4x8 @ 16x16)."""
    SPRITES_DIR.mkdir(parents=True, exist_ok=True)
    sheet = Image.new("RGBA", (128, 64), (0, 0, 0, 0))
    for row_idx, (_name, palette) in enumerate(ROBOT_PALETTES):
        for col_idx, frame_rows in enumerate(ROBOT_BUNNY_FRAMES):
            sprite = _render_ascii_sprite(frame_rows, palette, 16, 16)
            sheet.paste(sprite, (col_idx * 16, row_idx * 16))
    out_path = SPRITES_DIR / "robot_bunny_sheet.png"
    sheet.save(out_path)
    return out_path



# ---------------------------------------------------------------------------
# 3. Meadow Tileset (128x32: 8 cols x 2 rows @ 16x16)
# ---------------------------------------------------------------------------
# Tile layout:
# (0, 0): grass-top dirt
# (1, 0): subsoil dirt
# (2, 0): mossy stone platform
# (3, 0): water surface frame 1
# (4, 0): water surface frame 2
# (5, 0): deep water
# (6, 0): slippery ice slab
# (7, 0): spring resting
# (0, 1): spring extended


def _make_dirt_tile(rng: np.random.Generator, with_grass_top: bool) -> Image.Image:
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    px = img.load()

    dirt_palette = [
        (134, 82, 46, 255),
        (148, 94, 54, 255),
        (114, 66, 36, 255),
        (162, 108, 64, 255),
    ]
    pebble_dark = (86, 54, 34, 255)
    pebble_light = (156, 128, 102, 255)

    for y in range(16):
        for x in range(16):
            r = rng.random()
            if r < 0.08:
                c = pebble_dark
            elif r < 0.13:
                c = pebble_light
            else:
                idx = int(rng.integers(0, len(dirt_palette)))
                c = dirt_palette[idx]
            px[x, y] = c

    if with_grass_top:
        grass_outline = (26, 62, 26, 255)
        grass_dark = (46, 124, 42, 255)
        grass_mid = (76, 172, 58, 255)
        grass_hi = (122, 214, 78, 255)
        dirt_shadow = (78, 44, 24, 255)

        overhang = [4, 5, 4, 3, 4, 5, 5, 4, 3, 4, 5, 4, 3, 4, 5, 4]
        for x in range(16):
            depth = overhang[x]
            px[x, 0] = grass_outline
            px[x, 1] = grass_hi if (x % 3 != 0) else grass_mid
            for y in range(2, depth):
                px[x, y] = grass_mid if y == 2 else grass_dark
            px[x, depth] = dirt_shadow
            if x % 5 == 2:
                px[x, 0] = grass_hi
    return img


def _make_mossy_stone_tile() -> Image.Image:
    # 16x16 stone bricks with draped moss on top
    template = [
        "GGGGGGGGGGGGGGGG",
        "GHGGHGGHGGGHGGHG",
        "GDGGDGGDGGGDGGDG",
        "ODGGODDDDDODGGDO",
        "OLLLLLLLOOLLLLLO",
        "OLMMMMMSOOLMMMMS",
        "OLMMMMMSOOLMMMMS",
        "OSSSSSSSOOSSSSSS",
        "OOOOOOOOOOOOOOOO",
        "LLLLOOLLLLLLLLOO",
        "MMMMSOLMMMMMMMSO",
        "MMMMSOLMMMMMMMSO",
        "SSSSSOOSSSSSSSSO",
        "OOOOOOOOOOOOOOOD",
        "OLMMMMSSOLMMMMMS",
        "OOOOOOOOOOOOOOOO",
    ]
    palette: Dict[str, RGBA] = {
        "O": (36, 40, 50, 255),
        "L": (154, 164, 178, 255),
        "M": (118, 128, 144, 255),
        "S": (82, 90, 104, 255),
        "G": (68, 164, 56, 255),
        "H": (116, 208, 76, 255),
        "D": (42, 110, 38, 255),
    }
    return _render_ascii_sprite(template, palette, 16, 16)


def _make_water_surface_tile(frame: int) -> Image.Image:
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    px = img.load()
    foam = (224, 248, 255, 240)
    crest = (112, 212, 248, 235)
    body = (44, 126, 214, 225)
    deep = (34, 98, 182, 230)
    shimmer = (86, 168, 238, 230)

    shift = 0 if frame == 0 else 4
    for x in range(16):
        wx = (x + shift) % 16
        wave_y = 2 if (wx % 8) < 4 else 3
        if wx % 8 in (1, 2):
            wave_y = 1
        px[x, wave_y] = foam
        px[x, wave_y + 1] = crest
        for y in range(wave_y + 2, 16):
            if (y == 7 and (x + shift) % 6 < 2) or (y == 12 and (x + 3 - shift) % 7 < 2):
                px[x, y] = shimmer
            elif y >= 11:
                px[x, y] = deep
            else:
                px[x, y] = body
    return img


def _make_deep_water_tile() -> Image.Image:
    img = Image.new("RGBA", (16, 16), (32, 94, 178, 232))
    px = img.load()
    darker = (24, 74, 150, 238)
    shimmer = (64, 140, 216, 230)
    for y in range(16):
        for x in range(16):
            if (y % 6 == 2 and (x + y) % 7 < 2):
                px[x, y] = shimmer
            elif (y % 4 == 0 and x % 5 == 1):
                px[x, y] = darker
    return img


def _make_ice_tile() -> Image.Image:
    template = [
        "OOOOOOOOOOOOOOOO",
        "OHHHHHHHHHHHHHHO",
        "OHBBWHBBBBWHBBBO",
        "OHBWHBBBBWHBBBBO",
        "OBWHBBBBWHBBBBBO",
        "OBBBBBBBBBBBBBBO",
        "OBBBBBWHBBBBBBBO",
        "OBBBBWHBBBBBBBBO",
        "OBBBWHBBBBSSSSBO",
        "OBBBBBBBBBSSSSBO",
        "OBSSSSBBBBBBBBBO",
        "OBSSSSSSBBBBSSBO",
        "OSSSSSSSSSSSSSSO",
        "OODDDDDDDDDDDDOO",
        "O.OD.OOD..OOD.OO",
        "...O...O....O...",
    ]
    palette: Dict[str, RGBA] = {
        "O": (40, 92, 128, 255),
        "H": (232, 252, 255, 255),
        "W": (255, 255, 255, 255),
        "B": (140, 222, 248, 255),
        "S": (96, 186, 224, 255),
        "D": (68, 148, 192, 255),
    }
    return _render_ascii_sprite(template, palette, 16, 16)


def _make_spring_tile(extended: bool) -> Image.Image:
    if not extended:
        template = [
            "................",
            "................",
            "................",
            "................",
            "................",
            "................",
            "................",
            "..OOOOOOOOOOOO..",
            ".OHRRRRRRRRRRHO.",
            ".OYYYYYYYYYYYYO.",
            "..OOOOOOOOOOOO..",
            "....OCCCCCCOO...",
            "....OSSSSSSOO...",
            "..OOOOOOOOOOOO..",
            ".OLLLLLLLLLLLLOO",
            ".OOOOOOOOOOOOOOO",
        ]
    else:
        template = [
            "................",
            "..OOOOOOOOOOOO..",
            ".OHRRRRRRRRRRHO.",
            ".OYYYYYYYYYYYYO.",
            "..OOOOOOOOOOOO..",
            ".....OCCSOO.....",
            "......OCCSO.....",
            ".....OCCSOO.....",
            "......OCCSO.....",
            ".....OCCSOO.....",
            "......OCCSO.....",
            ".....OCCSOO.....",
            "......OCCSO.....",
            "..OOOOOOOOOOOO..",
            ".OLLLLLLLLLLLLOO",
            ".OOOOOOOOOOOOOOO",
        ]
    palette: Dict[str, RGBA] = {
        "O": (26, 24, 34, 255),
        "R": (222, 54, 44, 255),
        "H": (255, 124, 92, 255),
        "Y": (248, 206, 62, 255),
        "C": (214, 222, 236, 255),
        "S": (128, 138, 156, 255),
        "L": (164, 174, 190, 255),
    }
    return _render_ascii_sprite(template, palette, 16, 16)


def generate_tileset() -> pathlib.Path:
    """Generate `client/assets/tiles/tileset.png` (128x32, 8x2 @ 16x16)."""
    TILES_DIR.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(SEED)
    tileset = Image.new("RGBA", (128, 32), (0, 0, 0, 0))

    tiles_row0 = [
        _make_dirt_tile(rng, with_grass_top=True),
        _make_dirt_tile(rng, with_grass_top=False),
        _make_mossy_stone_tile(),
        _make_water_surface_tile(0),
        _make_water_surface_tile(1),
        _make_deep_water_tile(),
        _make_ice_tile(),
        _make_spring_tile(extended=False),
    ]
    for idx, tile in enumerate(tiles_row0):
        tileset.paste(tile, (idx * 16, 0))

    tileset.paste(_make_spring_tile(extended=True), (0, 16))

    out_path = TILES_DIR / "tileset.png"
    tileset.save(out_path)
    return out_path


# ---------------------------------------------------------------------------
# 4. Meadow Parallax Backdrop (400x256)
# ---------------------------------------------------------------------------


def generate_meadow_bg() -> pathlib.Path:
    """Generate `client/assets/bg/meadow_bg.png` (400x256 daytime pixel-art)."""
    BG_DIR.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(SEED + 100)
    w, h = 400, 256
    arr = np.zeros((h, w, 4), dtype=np.uint8)

    # Bayer 4x4 ordered dither matrix for crisp retro sky bands
    bayer = (
        np.array(
            [
                [0, 8, 2, 10],
                [12, 4, 14, 6],
                [3, 11, 1, 9],
                [15, 7, 13, 5],
            ],
            dtype=np.float32,
        )
        / 16.0
    )

    sky_stops = [
        np.array([92, 168, 238], dtype=np.float32),
        np.array([124, 194, 246], dtype=np.float32),
        np.array([158, 218, 252], dtype=np.float32),
        np.array([194, 236, 254], dtype=np.float32),
    ]

    for y in range(h):
        t = min(1.0, y / 185.0) * (len(sky_stops) - 1)
        idx = min(len(sky_stops) - 2, int(t))
        frac = t - idx
        c0 = sky_stops[idx]
        c1 = sky_stops[idx + 1]
        for x in range(w):
            choose_next = frac > bayer[y % 4, x % 4]
            col = c1 if choose_next else c0
            arr[y, x, :3] = col.astype(np.uint8)
            arr[y, x, 3] = 255

    # Warm daytime sun in upper-left sky
    sun_cx, sun_cy = 74, 44
    for y in range(18, 72):
        for x in range(46, 102):
            dist2 = (x - sun_cx) ** 2 + (y - sun_cy) ** 2
            if dist2 <= 11 ** 2:
                arr[y, x] = [255, 250, 206, 255]
            elif dist2 <= 16 ** 2 and ((x + y) % 2 == 0):
                arr[y, x] = [248, 246, 218, 255]

    img = Image.fromarray(arr, mode="RGBA").copy()
    px = img.load()

    # Fluffy pixel-art clouds
    def draw_cloud(cx: int, cy: int, scale: float) -> None:
        blobs = [
            (-18, 3, 10),
            (-7, -2, 13),
            (6, -3, 12),
            (18, 2, 9),
            (0, 4, 11),
        ]
        cloud_hi = (255, 255, 255, 255)
        cloud_mid = (232, 244, 254, 255)
        cloud_bot = (196, 222, 244, 255)
        min_x = int(cx - 32 * scale)
        max_x = int(cx + 32 * scale)
        min_y = int(cy - 18 * scale)
        max_y = int(cy + 16 * scale)
        for y in range(max(0, min_y), min(h, max_y)):
            for x in range(max(0, min_x), min(w, max_x)):
                inside = False
                for bx, by, br in blobs:
                    dx = (x - (cx + bx * scale)) / (br * scale)
                    dy = (y - (cy + by * scale)) / (br * scale * 0.72)
                    if dx * dx + dy * dy <= 1.0:
                        inside = True
                        break
                if inside and y <= cy + int(7 * scale):
                    if y < cy - int(2 * scale):
                        px[x, y] = cloud_hi
                    elif y < cy + int(4 * scale):
                        px[x, y] = cloud_mid
                    else:
                        px[x, y] = cloud_bot

    for cx, cy, sc in [(148, 40, 1.1), (255, 58, 0.9), (345, 34, 1.25), (34, 72, 0.75)]:
        draw_cloud(cx, cy, sc)

    # Distant blue-green rolling hills
    far_ridge = np.zeros(w, dtype=np.int32)
    for x in range(w):
        ridge = (
            152
            - 18 * np.sin(x * 0.017 + 0.6)
            - 9 * np.sin(x * 0.043 + 1.4)
        )
        far_ridge[x] = int(ridge)
        for y in range(far_ridge[x], h):
            if y == far_ridge[x]:
                px[x, y] = (126, 178, 158, 255)
            else:
                px[x, y] = (110, 166, 148, 255)

    # Midground green hills + trees
    mid_ridge = np.zeros(w, dtype=np.int32)
    for x in range(w):
        ridge = (
            174
            - 14 * np.sin(x * 0.022 + 2.3)
            - 7 * np.cos(x * 0.052)
        )
        mid_ridge[x] = int(ridge)

    # Distant pixel pine & oak silhouettes seated on midground ridge
    tree_xs = [22, 58, 94, 138, 176, 214, 268, 308, 352, 384]
    for i, tx in enumerate(tree_xs):
        base_y = int(mid_ridge[tx]) + 1
        if i % 2 == 0:
            # Pine tree
            tree_h = 20 + int(rng.integers(0, 7))
            for ty in range(tree_h):
                y = base_y - tree_h + ty
                if 0 <= y < h:
                    half_w = max(1, (ty * 7) // tree_h)
                    for dx in range(-half_w, half_w + 1):
                        xx = tx + dx
                        if 0 <= xx < w:
                            px[xx, y] = (
                                (84, 148, 86, 255)
                                if dx <= 0
                                else (64, 122, 72, 255)
                            )
        else:
            # Rounded meadow tree
            crown_y = base_y - 11
            for dy in range(-8, 5):
                for dx in range(-7, 8):
                    if dx * dx + (dy * 1.2) ** 2 <= 49:
                        xx, yy = tx + dx, crown_y + dy
                        if 0 <= xx < w and 0 <= yy < h:
                            px[xx, yy] = (
                                (98, 166, 86, 255)
                                if dx + dy < 0
                                else (72, 136, 74, 255)
                            )
            for ty in range(base_y - 6, base_y + 1):
                for dx in (-1, 0):
                    if 0 <= tx + dx < w and 0 <= ty < h:
                        px[tx + dx, ty] = (92, 64, 46, 255)

    for x in range(w):
        ry = mid_ridge[x]
        for y in range(ry, h):
            if y == ry:
                px[x, y] = (104, 178, 88, 255)
            elif y < ry + 18:
                px[x, y] = (86, 156, 78, 255)
            else:
                px[x, y] = (72, 136, 68, 255)

    # Subtle foreground meadow wildflowers & grass tufts
    for _ in range(55):
        fx = int(rng.integers(4, w - 4))
        fy = int(rng.integers(max(182, mid_ridge[fx] + 4), h - 4))
        px[fx, fy] = (108, 182, 86, 255)
        if rng.random() < 0.35:
            flower_col = (248, 232, 124, 255) if rng.random() < 0.6 else (246, 174, 198, 255)
            px[fx, fy - 1] = flower_col

    out_path = BG_DIR / "meadow_bg.png"
    img.save(out_path)
    return out_path


# ---------------------------------------------------------------------------
# 5. Particle Sprite Sheet (64x32: 8 cols x 4 rows @ 8x8)
# ---------------------------------------------------------------------------
# Row 0 (y=0..7):   Gore gibs / blood drops (cols 0..7)
# Row 1 (y=8..15):  Bunny fur tufts (cols 0..1 Dott, 2..3 Jiffy, 4..5 Fizz, 6..7 Mijji)
# Row 2 (y=16..23): Cols 0..3 non-gore star/smoke puffs; Cols 4..7 water droplets
# Row 3 (y=24..31): Cols 0..1 ambient fly (2 frames); Cols 2..3 golden meadow bug; Cols 4..7 sparkles


def generate_particles() -> pathlib.Path:
    """Generate `client/assets/sprites/particles.png` (64x32, 8x4 @ 8x8)."""
    SPRITES_DIR.mkdir(parents=True, exist_ok=True)
    sheet = Image.new("RGBA", (64, 32), (0, 0, 0, 0))

    gore_pal: Dict[str, RGBA] = {
        "O": (54, 10, 14, 255),
        "D": (132, 18, 26, 255),
        "R": (204, 34, 42, 255),
        "H": (244, 88, 86, 255),
        "B": (244, 212, 192, 255),
    }
    gore_templates = [
        [
            "........",
            "..OOOO..",
            ".OHRRDO.",
            ".ORRRDO.",
            ".ODRDBO.",
            "..ODDO..",
            "...OO...",
            "........",
        ],
        [
            "........",
            "........",
            "..OOO...",
            ".OHRDO..",
            ".ORRDO..",
            "..ODO...",
            "........",
            "........",
        ],
        [
            "........",
            "...OO...",
            "..OHRO..",
            "..ORDO..",
            "...OO...",
            "........",
            "........",
            "........",
        ],
        [
            "........",
            "..OOOO..",
            ".OBRRDO.",
            ".ORBBDO.",
            "..ODDO..",
            "........",
            "........",
            "........",
        ],
        [
            "........",
            "...O....",
            "..ORO...",
            ".OHRDO..",
            "..ODO...",
            "...O....",
            "........",
            "........",
        ],
        [
            "........",
            "........",
            "...OO...",
            "..OHDO..",
            "..ORDO..",
            "...OO...",
            "........",
            "........",
        ],
        [
            "........",
            "..OO.OO.",
            ".ORRO.O.",
            "..ODDO..",
            "...OO...",
            "........",
            "........",
            "........",
        ],
        [
            "........",
            "........",
            "........",
            "...OO...",
            "..ORDO..",
            "...OO...",
            "........",
            "........",
        ],
    ]
    for col, tpl in enumerate(gore_templates):
        sheet.paste(_render_ascii_sprite(tpl, gore_pal, 8, 8), (col * 8, 0))

    fur_tpl_a = [
        "........",
        "..OO....",
        ".OHBO...",
        "..OBSO..",
        "..OOSSO.",
        "....OO..",
        "........",
        "........",
    ]
    fur_tpl_b = [
        "........",
        "....OO..",
        "..OOHBO.",
        ".OHBBSO.",
        "..OSSO..",
        "...OO...",
        "........",
        "........",
    ]
    for slot_idx, (_name, bpal) in enumerate(BUNNY_PALETTES):
        sheet.paste(_render_ascii_sprite(fur_tpl_a, bpal, 8, 8), ((slot_idx * 2) * 8, 8))
        sheet.paste(_render_ascii_sprite(fur_tpl_b, bpal, 8, 8), ((slot_idx * 2 + 1) * 8, 8))

    puff_pal: Dict[str, RGBA] = {
        "O": (72, 68, 88, 220),
        "W": (255, 255, 255, 245),
        "C": (228, 234, 246, 230),
        "Y": (255, 226, 98, 255),
        "G": (244, 178, 54, 255),
    }
    puff_templates = [
        [
            "...YY...",
            ".Y.WW.Y.",
            "..YWWY..",
            "YYWWWWYY",
            "..YWWY..",
            ".Y.WW.Y.",
            "...YY...",
            "........",
        ],
        [
            "..OOOO..",
            ".OWWWCO.",
            "OWWWWWCO",
            "OWWWCCCO",
            ".OCCCCC.",
            "..OOOO..",
            "........",
            "........",
        ],
        [
            "........",
            "..OOOO..",
            ".OWWWCO.",
            ".OWCCCO.",
            "..OOOO..",
            "........",
            "........",
            "........",
        ],
        [
            "...GG...",
            "...YY...",
            ".GYWWYG.",
            "...YY...",
            "...GG...",
            "........",
            "........",
            "........",
        ],
    ]
    for col, tpl in enumerate(puff_templates):
        sheet.paste(_render_ascii_sprite(tpl, puff_pal, 8, 8), (col * 8, 16))

    water_pal: Dict[str, RGBA] = {
        "O": (30, 82, 152, 235),
        "B": (74, 174, 242, 235),
        "W": (224, 248, 255, 245),
    }
    water_templates = [
        [
            "...OO...",
            "..OWBO..",
            "..OBBO..",
            "..OBBO..",
            "...OO...",
            "........",
            "........",
            "........",
        ],
        [
            "........",
            "...OO...",
            "..OWBO..",
            "..OBBO..",
            "...OO...",
            "........",
            "........",
            "........",
        ],
        [
            "........",
            "........",
            "...OO...",
            "..OWBO..",
            "...OO...",
            "........",
            "........",
            "........",
        ],
        [
            "..OO....",
            ".OWBO...",
            "..OO.OO.",
            "....OBBO",
            ".....OO.",
            "........",
            "........",
            "........",
        ],
    ]
    for i, tpl in enumerate(water_templates):
        sheet.paste(_render_ascii_sprite(tpl, water_pal, 8, 8), ((4 + i) * 8, 16))

    fly_pal: Dict[str, RGBA] = {
        "K": (26, 22, 32, 255),
        "B": (64, 58, 76, 255),
        "W": (228, 242, 255, 220),
        "Y": (248, 232, 112, 255),
        "G": (212, 174, 56, 255),
    }
    row3_templates = [
        # Col 0: fly wings up
        [
            "........",
            "..WW.WW.",
            "..WKWKW.",
            "...KKK..",
            "..KBK...",
            "........",
            "........",
            "........",
        ],
        # Col 1: fly wings down
        [
            "........",
            "........",
            "...KKK..",
            "..WKBKW.",
            "..WW.WW.",
            "........",
            "........",
            "........",
        ],
        # Col 2: meadow firefly frame 1
        [
            "........",
            "..WW.WW.",
            "..WKYKW.",
            "...KYK..",
            "..KGY...",
            "........",
            "........",
            "........",
        ],
        # Col 3: meadow firefly frame 2
        [
            "........",
            "........",
            "...KYK..",
            "..WKYKW.",
            "..WW.WW.",
            "........",
            "........",
            "........",
        ],
        # Col 4..7: sparkle / dust motes
        [
            "........",
            "...W....",
            "..WWW...",
            "...W....",
            "........",
            "........",
            "........",
            "........",
        ],
        [
            "........",
            "...Y....",
            "..YWY...",
            "...Y....",
            "........",
            "........",
            "........",
            "........",
        ],
        [
            "........",
            "........",
            "...WW...",
            "...WW...",
            "........",
            "........",
            "........",
            "........",
        ],
        [
            "........",
            "........",
            "...Y....",
            "........",
            "........",
            "........",
            "........",
            "........",
        ],
    ]
    for col, tpl in enumerate(row3_templates):
        sheet.paste(_render_ascii_sprite(tpl, fly_pal, 8, 8), (col * 8, 24))

    out_path = SPRITES_DIR / "particles.png"
    sheet.save(out_path)
    return out_path


# ---------------------------------------------------------------------------
# 6. Retro Synthesized 16-bit Mono 22050 Hz WAV SFX
# ---------------------------------------------------------------------------


def _write_wav(path: pathlib.Path, samples: np.ndarray) -> pathlib.Path:
    """Normalize safely and write 16-bit signed mono PCM WAV at 22050 Hz."""
    peak = float(np.max(np.abs(samples)))
    if peak > 1e-6:
        samples = samples / max(peak, 1.0) * 0.82
    pcm = np.clip(samples * 32767.0, -32767.0, 32767.0).astype(np.int16)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(pcm.tobytes())
    return path


def _time_axis(duration_s: float) -> np.ndarray:
    n = max(1, int(round(duration_s * SAMPLE_RATE)))
    return np.arange(n, dtype=np.float64) / SAMPLE_RATE


def generate_sfx() -> List[pathlib.Path]:
    """Generate 7 retro synthesized 16-bit mono 22050 Hz WAV sound effects."""
    SFX_DIR.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(SEED + 200)
    generated: List[pathlib.Path] = []

    # 1. jump.wav: crisp upward retro pulse/triangle sweep
    t = _time_axis(0.13)
    freq = np.linspace(240.0, 660.0, len(t))
    phase = 2.0 * np.pi * np.cumsum(freq) / SAMPLE_RATE
    env = np.exp(-t * 18.0) * np.minimum(1.0, t / 0.008)
    wave_jump = (0.65 * np.sign(np.sin(phase)) + 0.35 * np.sin(phase * 2.0)) * env
    generated.append(_write_wav(SFX_DIR / "jump.wav", wave_jump))

    # 2. stomp_splat.wav: low thud + crunchy burst
    t = _time_axis(0.24)
    thud_freq = 165.0 * np.exp(-t * 14.0) + 48.0
    thud_phase = 2.0 * np.pi * np.cumsum(thud_freq) / SAMPLE_RATE
    thud = np.sin(thud_phase) * np.exp(-t * 16.0)
    noise = rng.uniform(-1.0, 1.0, len(t))
    # Simple 3-tap lowpass for crunchy retro splat
    filtered_noise = np.convolve(noise, np.array([0.45, 0.35, 0.20]), mode="same")
    splat = filtered_noise * np.exp(-t * 13.0) * (0.5 + 0.5 * np.sin(2.0 * np.pi * 28.0 * t))
    wave_stomp = (0.65 * thud + 0.55 * splat) * np.minimum(1.0, t / 0.004)
    generated.append(_write_wav(SFX_DIR / "stomp_splat.wav", wave_stomp))

    # 3. puff.wav: gentle non-gore comic pop + soft sparkle
    t = _time_axis(0.17)
    pop_freq = np.linspace(520.0, 260.0, len(t))
    pop_phase = 2.0 * np.pi * np.cumsum(pop_freq) / SAMPLE_RATE
    pop = np.sin(pop_phase) * np.exp(-t * 22.0)
    airy = rng.uniform(-1.0, 1.0, len(t)) * np.exp(-t * 28.0) * 0.25
    chime = np.sin(2.0 * np.pi * 880.0 * t) * np.exp(-t * 18.0) * 0.28
    generated.append(_write_wav(SFX_DIR / "puff.wav", pop + airy + chime))

    # 4. spring.wav: classic bouncy boing
    t = _time_axis(0.32)
    boing_freq = 280.0 + 360.0 * (t / 0.32) + 55.0 * np.sin(2.0 * np.pi * 24.0 * t)
    boing_phase = 2.0 * np.pi * np.cumsum(boing_freq) / SAMPLE_RATE
    env = np.exp(-t * 7.5) * np.minimum(1.0, t / 0.006)
    wave_spring = (0.75 * np.sin(boing_phase) + 0.25 * np.sin(2.0 * boing_phase)) * env
    generated.append(_write_wav(SFX_DIR / "spring.wav", wave_spring))

    # 5. splash.wav: water splash + bubbly droplets
    t = _time_axis(0.28)
    raw = rng.uniform(-1.0, 1.0, len(t))
    smooth = np.convolve(raw, np.ones(6) / 6.0, mode="same")
    bub1 = np.sin(2.0 * np.pi * np.cumsum(np.linspace(380.0, 740.0, len(t))) / SAMPLE_RATE)
    bub2 = np.sin(2.0 * np.pi * np.cumsum(np.linspace(520.0, 920.0, len(t))) / SAMPLE_RATE)
    env = np.exp(-t * 10.5) * np.minimum(1.0, t / 0.01)
    wave_splash = (0.68 * smooth + 0.22 * bub1 + 0.16 * bub2) * env
    generated.append(_write_wav(SFX_DIR / "splash.wav", wave_splash))

    # 6. countdown.wav: crisp retro square beep
    t = _time_axis(0.14)
    tone = 0.65 * np.sign(np.sin(2.0 * np.pi * 587.33 * t)) + 0.35 * np.sin(
        2.0 * np.pi * 587.33 * t
    )
    env = np.exp(-t * 14.0) * np.minimum(1.0, t / 0.004)
    generated.append(_write_wav(SFX_DIR / "countdown.wav", tone * env))

    # 7. victory.wav: 4-note chiptune fanfare arpeggio (C5-E5-G5-C6)
    notes = [(523.25, 0.11), (659.25, 0.11), (783.99, 0.11), (1046.50, 0.45)]
    parts: List[np.ndarray] = []
    for idx, (nf, dur) in enumerate(notes):
        nt = _time_axis(dur)
        vib = 1.0 + (0.008 * np.sin(2.0 * np.pi * 6.0 * nt) if idx == 3 else 0.0)
        ph = 2.0 * np.pi * np.cumsum(nf * vib) / SAMPLE_RATE
        harm = np.sin(ph * 1.5) * 0.25 if idx == 3 else 0.0
        n_env = np.exp(-nt * (4.0 if idx == 3 else 10.0)) * np.minimum(1.0, nt / 0.006)
        parts.append((0.65 * np.sign(np.sin(ph)) + 0.35 * np.sin(ph) + harm) * n_env)
    generated.append(_write_wav(SFX_DIR / "victory.wav", np.concatenate(parts)))

    return generated


def main() -> None:
    synced = sync_shared_json()
    bunny_path = generate_bunny_sheet()
    robot_bunny_path = generate_robot_bunny_sheet()
    tileset_path = generate_tileset()
    bg_path = generate_meadow_bg()
    particles_path = generate_particles()
    sfx_paths = generate_sfx()

    print(f"[gen_assets] Synced {len(synced)} shared JSON files -> {CLIENT_DATA_DIR}")
    for p in synced:
        print(f"  - {p.relative_to(ROOT_DIR)}")
    print("[gen_assets] Generated PNG assets:")
    for p in (bunny_path, robot_bunny_path, tileset_path, bg_path, particles_path):
        print(f"  - {p.relative_to(ROOT_DIR)}")
    print(f"[gen_assets] Generated {len(sfx_paths)} WAV SFX:")
    for p in sfx_paths:
        print(f"  - {p.relative_to(ROOT_DIR)}")


if __name__ == "__main__":
    main()
