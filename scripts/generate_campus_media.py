#!/usr/bin/env python3
"""Create a polished campus image gallery and a standalone preview video.

The BMPs are authored at 640x480, 24-bit BI_RGB so they can be copied to the
FPGA player's FAT32 SD-card root as IMG001.BMP through IMG006.BMP. The MP4 is
for PC/browser presentation only; this FPGA project does not decode video.

Requires Pillow. OpenCV is optional and only needed for the MP4 preview.
"""

from __future__ import annotations

import argparse
import math
import random
import struct
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageFilter


W, H = 640, 480
SCALE = 2
SCENES = [
    ("智慧校园", "SMART CAMPUS", "科技与日常，在这里相遇", "CAMPUS LIFE  /  DIGITAL FUTURE", "#75D9D0"),
    ("书香校园", "A PLACE TO READ", "在安静的空间里，遇见更大的世界", "LIBRARY  /  KNOWLEDGE", "#FFD18A"),
    ("创客工坊", "BUILD WHAT'S NEXT", "把想法接入电路，让创意真正发生", "MAKER SPACE  /  FPGA LAB", "#62DDF0"),
    ("绿色校园", "GROW IN BALANCE", "让低碳成为校园里自然的一部分", "GREEN CAMPUS  /  CLEAN ENERGY", "#A7E37C"),
    ("运动嘉年华", "MOVE TOGETHER", "每一次奔跑，都让校园更有活力", "SPORTS  /  COMMUNITY", "#FFAA7F"),
    ("平安校园", "SAFE BY DESIGN", "清晰的信息，让每一步都更安心", "CAMPUS CARE  /  SAFETY", "#F4D774"),
]


def rgb(hex_color: str) -> tuple[int, int, int]:
    value = hex_color.lstrip("#")
    return tuple(int(value[i : i + 2], 16) for i in (0, 2, 4))


def mix(a: str | tuple[int, int, int], b: str | tuple[int, int, int], t: float):
    aa, bb = rgb(a) if isinstance(a, str) else a, rgb(b) if isinstance(b, str) else b
    return tuple(round(x + (y - x) * t) for x, y in zip(aa, bb))


def font_path(explicit: str | None) -> Path:
    candidates = [explicit] if explicit else []
    candidates += [
        r"C:\Windows\Fonts\NotoSansSC-VF.ttf",
        r"C:\Windows\Fonts\Dengb.ttf",
        r"C:\Windows\Fonts\simhei.ttf",
        r"C:\Windows\Fonts\msyh.ttc",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
        "/usr/share/fonts/truetype/noto/NotoSansCJK-Bold.ttc",
        "/System/Library/Fonts/PingFang.ttc",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return Path(candidate)
    raise RuntimeError(
        "No CJK font found. Install Noto Sans SC / DengXian / SimHei, or pass --font PATH."
    )


class Artboard:
    """Small-coordinate drawing facade over a 2x supersampled canvas."""

    def __init__(self, bg_top: str, bg_bottom: str, seed: int):
        self.image = Image.new("RGB", (W * SCALE, H * SCALE))
        self.draw = ImageDraw.Draw(self.image)
        self.fonts: dict[tuple[int, bool], ImageFont.FreeTypeFont] = {}
        self.rng = random.Random(seed)
        top, bottom = rgb(bg_top), rgb(bg_bottom)
        for y in range(H * SCALE):
            t = y / max(1, H * SCALE - 1)
            self.draw.line((0, y, W * SCALE, y), fill=mix(top, bottom, t))

    @staticmethod
    def p(v: float) -> int:
        return round(v * SCALE)

    def font(self, size: int, bold: bool = False):
        key = (size, bold)
        if key not in self.fonts:
            path = FONT_BOLD_PATH if bold else FONT_REGULAR
            font = ImageFont.truetype(str(path), self.p(size))
            if bold and path == FONT_REGULAR:
                try:
                    axes = font.get_variation_axes()
                    if axes:
                        font.set_variation_by_axes([
                            axis["maximum"] if "weight" in str(axis.get("name", "")).lower()
                            else axis["default"] for axis in axes
                        ])
                except (AttributeError, OSError, ValueError):
                    pass
            self.fonts[key] = font
        return self.fonts[key]

    def rect(self, box, fill, outline=None, width=1, radius=0):
        box = tuple(self.p(v) for v in box)
        if radius:
            self.draw.rounded_rectangle(box, radius=self.p(radius), fill=fill,
                                        outline=outline, width=self.p(width))
        else:
            self.draw.rectangle(box, fill=fill, outline=outline, width=self.p(width))

    def line(self, points, fill, width=1, joint="curve"):
        self.draw.line([(self.p(x), self.p(y)) for x, y in points], fill=fill,
                       width=self.p(width), joint=joint)

    def polygon(self, points, fill, outline=None):
        pts = [(self.p(x), self.p(y)) for x, y in points]
        self.draw.polygon(pts, fill=fill)
        if outline:
            self.draw.line(pts + [pts[0]], fill=outline, width=self.p(1), joint="curve")

    def ellipse(self, box, fill, outline=None, width=1):
        self.draw.ellipse(tuple(self.p(v) for v in box), fill=fill, outline=outline,
                          width=self.p(width))

    def arc(self, box, start, end, fill, width=1):
        self.draw.arc(tuple(self.p(v) for v in box), start, end, fill=fill,
                      width=self.p(width))

    def text(self, xy, value, size, fill, bold=False, stroke=0, stroke_fill=None,
             anchor=None):
        x, y = self.p(xy[0]), self.p(xy[1])
        self.draw.text((x, y), value, font=self.font(size, bold), fill=fill,
                       stroke_width=self.p(stroke), stroke_fill=stroke_fill,
                       anchor=anchor)

    def round_to_native(self) -> Image.Image:
        return self.image.resize((W, H), Image.Resampling.LANCZOS)


FONT_REGULAR: Path
FONT_BOLD_PATH: Path


def add_specks(a: Artboard, color: str, count=26, y_min=135, y_max=390):
    for _ in range(count):
        x = a.rng.uniform(22, 618)
        y = a.rng.uniform(y_min, y_max)
        r = a.rng.choice((0.6, 0.9, 1.2))
        a.ellipse((x - r, y - r, x + r, y + r), color)


def add_header(a: Artboard, idx: int, title: str, english: str, accent: str):
    a.ellipse((34, 34, 43, 43), accent)
    a.text((52, 31), "SMART CAMPUS  /  MEDIA GALLERY", 10, "#D4E3EF", bold=True)
    a.text((573, 30), f"{idx:02d} / 06", 11, "#E9F1F7", bold=True)
    a.text((36, 58), title, 38, "#FFFFFF", bold=True, stroke=0.4, stroke_fill="#18334C")
    a.text((39, 108), english, 10, accent, bold=True)
    a.line([(39, 127), (86, 127)], accent, 2)
    a.line([(91, 127), (604, 127)], "#496177", 1)


def add_footer(a: Artboard, idx: int, subtitle: str, accent: str):
    # A calm, translucent-looking dark footer keeps labels readable over any scene.
    a.rect((0, 414, 640, 480), "#102239")
    a.rect((0, 414, 6, 480), accent)
    a.text((32, 431), subtitle, 15, "#F5F8FA", bold=True)
    a.text((33, 456), "SMART CAMPUS MEDIA  •  640 × 480  •  RGB24", 8, "#A8BDCC", bold=True)
    for dot in range(6):
        color = accent if dot == idx - 1 else "#456074"
        a.ellipse((566 + dot * 12, 441, 572 + dot * 12, 447), color)


def scene_campus():
    a = Artboard("#152B4C", "#66A7AF", 1)
    add_specks(a, "#DFE7CA", 32)
    # Dawn sun, layered hills, a waterway, and a recognizable academic gate.
    a.ellipse((488, 151, 576, 239), "#F6C777")
    a.polygon([(0, 295), (105, 222), (190, 288), (300, 207), (420, 291), (535, 222), (640, 296), (640, 414), (0, 414)], "#345B68")
    a.polygon([(0, 330), (145, 280), (250, 330), (377, 267), (500, 331), (640, 286), (640, 414), (0, 414)], "#2C7372")
    # Academic building and central gate.
    a.rect((165, 237, 475, 365), "#D7B88D", "#F2D8AC", 2, 4)
    a.polygon([(148, 238), (320, 179), (492, 238)], "#F4D6A6")
    a.polygon([(162, 238), (320, 194), (478, 238)], "#425C6C")
    a.rect((183, 250, 457, 267), "#253D56")
    a.rect((297, 271, 343, 365), "#314E61", radius=20)
    for row in range(3):
        for col in range(6):
            x, y = 187 + col * 46, 280 + row * 28
            if 2 <= col <= 3 and row == 2:
                continue
            a.rect((x, y, x + 22, y + 14), "#F6CE8A", radius=2)
            a.line([(x + 11, y), (x + 11, y + 14)], "#B78368", 1)
    # Forecourt, walkway and low planting.
    a.polygon([(268, 365), (372, 365), (425, 414), (216, 414)], "#D8C7A5")
    a.polygon([(0, 383), (155, 357), (244, 414), (0, 414)], "#41837B")
    a.polygon([(640, 379), (500, 352), (413, 414), (640, 414)], "#4B8B78")
    for x, y, r in [(76, 299, 34), (119, 311, 27), (548, 286, 39), (594, 315, 26)]:
        a.rect((x - 3, y + 13, x + 3, 69 + y), "#644F44")
        a.ellipse((x - r, y - r, x + r, y + r), "#78A77A")
        a.ellipse((x - r * .7, y - r * .9, x + r * .2, y - r * .1), "#92BC82")
    add_header(a, 1, "智慧校园", "A CONNECTED CAMPUS, MADE FOR PEOPLE", "#F8D17C")
    add_footer(a, 1, "科技与日常，在这里相遇", "#F8D17C")
    return a.round_to_native()


def scene_library():
    a = Artboard("#24365F", "#D18A76", 2)
    add_specks(a, "#FFE8BD", 36, 138, 300)
    a.ellipse((486, 153, 540, 207), "#FFD19A")
    # Pavilion silhouette behind the library.
    a.polygon([(50, 335), (132, 257), (207, 335)], "#536484")
    a.polygon([(432, 326), (513, 246), (594, 326)], "#405975")
    # Warm, welcoming library with a deep central entrance.
    a.rect((147, 222, 493, 376), "#E8C49A", "#FFE2B5", 2, 4)
    a.polygon([(132, 224), (320, 175), (508, 224)], "#F1D5AF")
    a.polygon([(152, 224), (320, 190), (488, 224)], "#5B6276")
    a.rect((167, 238, 473, 253), "#544E5D")
    for col in range(7):
        x = 167 + col * 44
        a.rect((x, 267, x + 27, 324), "#56728A", radius=2)
        a.rect((x + 3, 270, x + 24, 317), "#B8D8D1")
        a.line([(x + 8, 270), (x + 8, 317)], "#E4D5AE", 1)
    a.rect((289, 257, 351, 376), "#324860", radius=25)
    a.rect((299, 291, 341, 375), "#E6B67E", radius=18)
    # Open book in the foreground, with page lines and a fine spine.
    a.polygon([(172, 347), (303, 326), (320, 340), (320, 388), (196, 379)], "#F4E9D1")
    a.polygon([(320, 340), (337, 326), (468, 347), (444, 379), (320, 388)], "#FFF4DC")
    a.line([(320, 340), (320, 388)], "#BC9178", 2)
    for k in range(4):
        y = 350 + k * 8
        a.line([(205, y), (293, y - 12)], "#B3B8BA", 1)
        a.line([(348, y - 12), (435, y)], "#B3B8BA", 1)
    for x, y, color in [(77, 328, "#5C9679"), (550, 318, "#568A73")]:
        a.rect((x - 4, y, x + 4, 374), "#725849")
        for dx, dy, r in [(-16, 0, 17), (0, -20, 19), (15, -2, 18)]:
            a.ellipse((x + dx - r, y + dy - r, x + dx + r, y + dy + r), color)
    add_header(a, 2, "书香校园", "A PLACE TO READ, DREAM AND DISCOVER", "#FFD49B")
    add_footer(a, 2, "在安静的空间里，遇见更大的世界", "#FFD49B")
    return a.round_to_native()


def scene_maker():
    a = Artboard("#071A33", "#183C5B", 3)
    add_specks(a, "#44BED0", 54, 138, 401)
    # Circuit traces radiate outward from the processor.
    traces = [
        [(316, 263), (220, 263), (220, 209), (130, 209)], [(316, 284), (183, 284), (183, 337), (82, 337)],
        [(324, 263), (420, 263), (420, 203), (527, 203)], [(324, 291), (447, 291), (447, 351), (562, 351)],
        [(306, 316), (260, 316), (260, 375), (183, 375)], [(334, 316), (376, 316), (376, 375), (472, 375)],
        [(293, 281), (247, 281), (247, 235), (205, 235)], [(347, 281), (393, 281), (393, 235), (437, 235)],
    ]
    for route in traces:
        a.line(route, "#2AA4B2", 2)
        for x, y in (route[0], route[-1]):
            a.ellipse((x - 4, y - 4, x + 4, y + 4), "#73F0E5")
    # Subtle board grid and IC pin tracks.
    for x in range(120, 561, 24):
        a.line([(x, 153), (x, 397)], "#1D3852", 1)
    for y in range(158, 398, 24):
        a.line([(75, y), (566, y)], "#1D3852", 1)
    a.rect((266, 218, 374, 330), "#1C344D", outline="#69E4E2", width=2, radius=9)
    a.rect((279, 231, 361, 317), "#0B243B", outline="#2DBAC3", width=2, radius=5)
    # Processor pins.
    for i in range(6):
        d = 278 + i * 14
        a.line([(d, 210), (d, 218)], "#74E7DB", 2)
        a.line([(d, 330), (d, 339)], "#74E7DB", 2)
        a.line([(258, 238 + i * 14), (266, 238 + i * 14)], "#74E7DB", 2)
        a.line([(374, 238 + i * 14), (382, 238 + i * 14)], "#74E7DB", 2)
    a.text((320, 264), "FPGA", 19, "#F4FFFF", bold=True, anchor="mm")
    a.text((320, 294), "LOGIC  /  PARALLEL", 7, "#8EE7E0", bold=True, anchor="mm")
    # Tiny indicator LEDs and a connector row.
    for i, c in enumerate(("#FBCC73", "#5DE0CA", "#FF718A", "#73B9FF")):
        a.ellipse((112 + i * 19, 362, 120 + i * 19, 370), c)
    a.rect((479, 283, 534, 322), "#132B45", outline="#4BB8C7", radius=4)
    for i in range(5):
        a.rect((485 + i * 9, 290, 490 + i * 9, 315), "#D3B77F")
    add_header(a, 3, "创客工坊", "IDEAS BECOME CIRCUITS, CODE AND PROTOTYPES", "#7DE6E1")
    add_footer(a, 3, "把想法接入电路，让创意真正发生", "#7DE6E1")
    return a.round_to_native()


def scene_green():
    a = Artboard("#70C6D0", "#E5CF9B", 4)
    add_specks(a, "#F6F3D7", 30, 136, 300)
    a.ellipse((484, 151, 548, 215), "#FFF1BC")
    # Rolling hills, lake and wind turbines.
    a.polygon([(0, 315), (94, 247), (188, 312), (293, 233), (394, 313), (512, 248), (640, 313), (640, 414), (0, 414)], "#7EAA79")
    a.polygon([(0, 343), (121, 294), (257, 344), (377, 286), (502, 343), (640, 296), (640, 414), (0, 414)], "#4C8C77")
    a.polygon([(0, 370), (128, 341), (262, 385), (387, 334), (511, 381), (640, 338), (640, 414), (0, 414)], "#367C72")
    a.polygon([(286, 366), (371, 347), (500, 378), (441, 414), (228, 414)], "#6AB9BD")
    # Wind turbines with delicate three-blade rotors.
    for x, base, r in [(115, 328, 48), (518, 330, 54), (418, 319, 36)]:
        hub = (x, base - r)
        a.line([(x, base), hub], "#EFF5DA", 3)
        for angle in (-90, 30, 150):
            rad = math.radians(angle)
            ex, ey = x + math.cos(rad) * r, base - r + math.sin(rad) * r
            a.line([hub, (ex, ey)], "#F5F2DB", 3)
        a.ellipse((x - 4, base - r - 4, x + 4, base - r + 4), "#F5F2DB")
    # Rows of solar panels in perspective.
    for row in range(3):
        y = 347 + row * 15
        left, right = 191 + row * 15, 359 + row * 17
        a.polygon([(left, y), (right, y + 2), (right + 16, y + 10), (left - 15, y + 8)], "#244F65", "#9AD2C1")
        for col in range(4):
            x = left + 31 * col
            a.line([(x, y + 1), (x - 10, y + 8)], "#7FC7CE", 1)
    for x, y in [(35, 344), (578, 350), (79, 371), (554, 378)]:
        a.rect((x - 3, y + 7, x + 3, y + 34), "#775A45")
        a.ellipse((x - 15, y - 7, x + 15, y + 18), "#568A65")
        a.ellipse((x - 11, y - 12, x + 6, y + 6), "#7EA96E")
    add_header(a, 4, "绿色校园", "CLEAN ENERGY, A LIGHTER FOOTPRINT", "#D8F0A5")
    add_footer(a, 4, "让低碳成为校园里自然的一部分", "#D8F0A5")
    return a.round_to_native()


def scene_sports():
    a = Artboard("#F39A78", "#6D5880", 5)
    add_specks(a, "#FFF0C8", 24, 138, 260)
    a.ellipse((482, 155, 530, 203), "#FFD488")
    # Stadium stands and the running track form strong sweeping diagonals.
    a.polygon([(0, 260), (214, 226), (376, 257), (640, 207), (640, 337), (0, 354)], "#3D4C70")
    for row in range(4):
        y = 273 + row * 16
        a.line([(28, y), (611, y - 24)], "#8192A5", 1)
    for col in range(18):
        x = 41 + col * 32
        y = 260 + int(col * -1.3)
        color = ["#FFC66E", "#F9E8C1", "#F2877B", "#91D0C7"][col % 4]
        a.ellipse((x, y, x + 5, y + 7), color)
    a.polygon([(0, 348), (640, 315), (640, 414), (0, 414)], "#D76665")
    a.line([(0, 377), (640, 344)], "#F6BC8A", 2)
    a.line([(0, 398), (640, 365)], "#F6BC8A", 2)
    a.arc((167, 326, 460, 507), 200, 340, "#F8D09A", 2)
    # Energetic runner silhouette, drawn as clean sports-poster geometry.
    a.ellipse((308, 228, 345, 265), "#182C49")
    a.line([(326, 263), (300, 306), (331, 327)], "#182C49", 13)
    a.line([(313, 277), (272, 269), (250, 292)], "#182C49", 10)
    a.line([(319, 279), (361, 282), (380, 266)], "#182C49", 10)
    a.line([(303, 304), (264, 329), (243, 362)], "#182C49", 12)
    a.line([(325, 323), (365, 338), (402, 365)], "#182C49", 12)
    a.ellipse((219, 285, 244, 310), "#FFD082")
    # Small ball and motion marks add a lively focal rhythm.
    a.ellipse((420, 302, 448, 330), "#FFD082", outline="#FFF1D4", width=2)
    a.arc((422, 304, 446, 328), 35, 210, "#BD6A68", 1)
    for i in range(3):
        a.line([(242 - i * 8, 260 + i * 8), (221 - i * 9, 256 + i * 8)], "#FFE1AD", 2)
    add_header(a, 5, "运动嘉年华", "MOVE TOGETHER, FEEL THE CAMPUS", "#FFD08A")
    add_footer(a, 5, "每一次奔跑，都让校园更有活力", "#FFD08A")
    return a.round_to_native()


def scene_safety():
    a = Artboard("#172746", "#566E78", 6)
    add_specks(a, "#F7D988", 35, 138, 390)
    # Evening campus and gently illuminated path.
    a.ellipse((495, 151, 541, 197), "#F4D989")
    a.polygon([(0, 302), (102, 250), (214, 303), (334, 224), (446, 300), (549, 247), (640, 294), (640, 414), (0, 414)], "#314E62")
    a.rect((73, 274, 232, 370), "#C9B58F")
    a.polygon([(60, 275), (151, 230), (245, 275)], "#E6CE9B")
    a.rect((253, 258, 412, 370), "#E3C89B")
    a.polygon([(239, 259), (332, 215), (427, 259)], "#F1DBB3")
    a.rect((435, 282, 570, 370), "#BFAE91")
    a.polygon([(424, 283), (503, 243), (582, 283)], "#D6C5A2")
    for bx, by, cols, rows in [(87, 289, 4, 2), (269, 273, 4, 2), (449, 296, 3, 2)]:
        for row in range(rows):
            for col in range(cols):
                x, y = bx + col * 33, by + row * 28
                a.rect((x, y, x + 18, y + 13), "#F5D68C", radius=2)
    a.rect((309, 294, 355, 370), "#39495A", radius=16)
    # Safety beacon and shield emblem.
    a.rect((318, 156, 322, 208), "#F0D9A0", radius=2)
    a.ellipse((303, 142, 338, 174), "#F8DA86")
    a.ellipse((310, 149, 331, 170), "#FFF0B3")
    a.polygon([(520, 254), (558, 268), (555, 309), (539, 329), (520, 341), (501, 329), (485, 309), (482, 268)], "#3F928F", "#A2DED1")
    a.line([(501, 292), (515, 306), (542, 279)], "#F5F4DB", 4)
    # Safe route lights along the walkway.
    a.polygon([(0, 388), (274, 347), (359, 347), (640, 392), (640, 414), (0, 414)], "#6C807D")
    for x, y in [(74, 375), (177, 361), (453, 365), (563, 381)]:
        a.ellipse((x - 5, y - 5, x + 5, y + 5), "#F5D988")
        a.line([(x, y + 5), (x, y + 18)], "#F0D48B", 2)
    add_header(a, 6, "平安校园", "CLEAR INFORMATION. CONFIDENT STEPS.", "#FFE49A")
    add_footer(a, 6, "清晰的信息，让每一步都更安心", "#FFE49A")
    return a.round_to_native()


SCENE_RENDERERS = [scene_campus, scene_library, scene_maker, scene_green, scene_sports, scene_safety]


def save_bmp24(image: Image.Image, path: Path):
    image = image.convert("RGB")
    image.save(path, format="BMP")
    header = path.read_bytes()[:54]
    if len(header) != 54:
        raise RuntimeError(f"Invalid BMP header: {path}")
    sig, size, _, offset, dib, width, height, planes, depth, compression = struct.unpack(
        "<2sI I I I i i H H I", header[:34]
    )
    if (sig, size, offset, dib, width, abs(height), planes, depth, compression) != (
        b"BM", path.stat().st_size, 54, 40, W, H, 1, 24, 0
    ):
        raise RuntimeError(f"BMP does not match the player's expected 24-bit BI_RGB format: {path}")


def make_video(images: list[Image.Image], root: Path):
    try:
        import cv2
        import numpy as np
    except ImportError:
        print("OpenCV not found; BMP/PNG gallery created, skipping MP4. Install opencv-python to enable it.")
        return None

    vw, vh, fps = 1280, 720, 24
    duration, transition, intro, outro = 3.6, 0.55, 2.4, 2.4
    total_seconds = intro + len(images) * duration + outro
    total_frames = round(intro * fps) + len(images) * round(duration * fps) + round(outro * fps)
    video_path = root / "preview" / "smart_campus_showcase.mp4"
    video_path.parent.mkdir(parents=True, exist_ok=True)
    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    writer = cv2.VideoWriter(str(video_path), fourcc, fps, (vw, vh))
    if not writer.isOpened():
        raise RuntimeError("OpenCV could not open the MP4 encoder (mp4v). BMP/PNG assets are ready.")

    # A restrained deep-blue stage gives every scene consistent cinematic framing.
    y = np.linspace(0, 1, vh, dtype=np.float32)[:, None, None]
    top = np.array([12, 22, 42], dtype=np.float32)[None, None, :]
    bottom = np.array([30, 57, 75], dtype=np.float32)[None, None, :]
    bg = np.repeat(np.repeat(top * (1 - y) + bottom * y, vw, axis=1), 1, axis=2).astype(np.uint8)
    stage = Image.fromarray(bg, "RGB")
    d = ImageDraw.Draw(stage)
    f_title = ImageFont.truetype(str(FONT_BOLD_PATH), 30)
    f_small = ImageFont.truetype(str(FONT_BOLD_PATH), 14)
    f_cn = ImageFont.truetype(str(FONT_BOLD_PATH), 38)
    f_body = ImageFont.truetype(str(FONT_REGULAR), 22)
    f_num = ImageFont.truetype(str(FONT_BOLD_PATH), 96)

    def build_page(index: int, phase: float) -> Image.Image:
        page = stage.copy()
        d = ImageDraw.Draw(page)
        accent = rgb(SCENES[index][4]) if index < len(images) else (120, 221, 216)
        d.ellipse((70, 48, 82, 60), fill=accent)
        d.text((96, 42), "SMART CAMPUS  /  VISUAL STORIES", font=f_small, fill=(194, 215, 228))
        d.text((1030, 42), "640 × 480 GALLERY", font=f_small, fill=(194, 215, 228))
        d.line((70, 74, 1210, 74), fill=(68, 91, 111), width=1)
        if 0 <= index < len(images):
            im = images[index]
            # Gentle Ken Burns motion; the underlying FPGA stills stay untouched.
            z = 1.0 + 0.035 * phase
            iw, ih = int(700 * z), int(525 * z)
            im = im.resize((iw, ih), Image.Resampling.LANCZOS)
            crop_x = max(0, (iw - 700) // 2 + int(6 * math.sin(phase * math.pi)))
            crop_y = max(0, (ih - 525) // 2)
            im = im.crop((crop_x, crop_y, crop_x + 700, crop_y + 525))
            # Soft shadow behind the image frame.
            shadow = Image.new("RGBA", (724, 548), (0, 0, 0, 0))
            sd = ImageDraw.Draw(shadow)
            sd.rounded_rectangle((7, 7, 717, 541), radius=18, fill=(0, 0, 0, 105))
            shadow = shadow.filter(ImageFilter.GaussianBlur(12))
            page.paste(shadow, (45, 112), shadow)
            page.paste(im, (58, 122))
            d = ImageDraw.Draw(page)
            # Caption panel with editorial number, concise Chinese title and support line.
            d.rounded_rectangle((807, 132, 1212, 602), radius=20, fill=(18, 38, 58), outline=(62, 91, 108), width=1)
            d.text((842, 164), f"CAMPUS STORY   {index + 1:02d} / 06", font=f_small, fill=accent)
            d.text((832, 211), f"{index + 1:02d}", font=f_num, fill=(53, 77, 93))
            d.text((846, 310), SCENES[index][0], font=f_cn, fill=(247, 250, 248), stroke_width=0)
            d.text((848, 372), SCENES[index][1], font=f_small, fill=accent)
            d.line((847, 411, 1160, 411), fill=(70, 99, 113), width=2)
            d.text((848, 440), SCENES[index][2], font=f_body, fill=(202, 218, 226))
            d.text((848, 535), "SMART CAMPUS MEDIA", font=f_small, fill=(133, 159, 173))
            # Bottom progress line.
            d.rounded_rectangle((70, 658, 1210, 664), radius=3, fill=(57, 78, 94))
            d.rounded_rectangle((70, 658, 70 + int(1140 * ((index + phase) / len(images))), 664),
                                radius=3, fill=accent)
        elif index == -1:
            d.text((72, 148), "SMART", font=ImageFont.truetype(str(FONT_BOLD_PATH), 78), fill=(248, 250, 247))
            d.text((72, 244), "CAMPUS", font=ImageFont.truetype(str(FONT_BOLD_PATH), 78), fill=(124, 224, 218))
            d.text((78, 364), "智享校园  ·  校园影像集", font=f_cn, fill=(238, 241, 232))
            d.text((82, 431), "A visual journey through campus life, creativity and care.",
                   font=f_body, fill=(184, 203, 214))
            # Geometric orbit motif.
            for rr, col in [(160, (55, 100, 119)), (116, (74, 143, 151)), (72, (123, 205, 180))]:
                d.ellipse((846 - rr, 355 - rr, 846 + rr, 355 + rr), outline=col, width=2)
            d.ellipse((830, 339, 862, 371), fill=(247, 205, 122))
            d.rounded_rectangle((70, 658, 1210, 664), radius=3, fill=(57, 78, 94))
            d.rounded_rectangle((70, 658, 160, 664), radius=3, fill=(124, 224, 218))
        else:
            d.text((72, 192), "把每一帧，留给校园生活", font=f_cn, fill=(248, 250, 247))
            d.text((76, 261), "SIX MOMENTS. ONE CONNECTED CAMPUS.", font=f_title, fill=(124, 224, 218))
            d.text((78, 336), "智慧 · 阅读 · 创造 · 绿色 · 活力 · 守护", font=f_body, fill=(194, 215, 224))
            d.text((78, 520), "SMART CAMPUS MEDIA  /  640 × 480 BMP GALLERY", font=f_small, fill=(139, 164, 178))
            d.rounded_rectangle((70, 658, 1210, 664), radius=3, fill=(124, 224, 218))
        return page

    intro_count = round(intro * fps)
    frame_count = 0

    def emit(page: Image.Image):
        nonlocal frame_count
        bgr = cv2.cvtColor(np.asarray(page), cv2.COLOR_RGB2BGR)
        writer.write(bgr)
        frame_count += 1

    for f in range(intro_count):
        emit(build_page(-1, f / max(1, intro_count - 1)))
    scene_frames = round(duration * fps)
    for i in range(len(images)):
        for f in range(scene_frames):
            phase = f / max(1, scene_frames - 1)
            current = build_page(i, phase)
            if i > 0 and f < round(transition * fps):
                blend = f / max(1, round(transition * fps) - 1)
                previous = build_page(i - 1, 1.0)
                current = Image.blend(previous, current, blend)
            emit(current)
    outro_count = round(outro * fps)
    for f in range(outro_count):
        emit(build_page(len(images), f / max(1, outro_count - 1)))
    writer.release()

    cap = cv2.VideoCapture(str(video_path))
    ok, probe = cap.read()
    count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    cap.release()
    if not ok or probe is None or (width, height) != (vw, vh) or count < 100:
        raise RuntimeError(f"MP4 validation failed: decoded={ok}, size={width}x{height}, frames={count}")
    if frame_count != total_frames or count != total_frames:
        raise RuntimeError(f"MP4 frame count mismatch: expected={total_frames}, written={frame_count}, decoded={count}")
    return video_path


def make_contact_sheet(images: list[Image.Image], root: Path):
    sheet = Image.new("RGB", (1280, 900), "#102239")
    draw = ImageDraw.Draw(sheet)
    title_font = ImageFont.truetype(str(FONT_BOLD_PATH), 28)
    small_font = ImageFont.truetype(str(FONT_BOLD_PATH), 16)
    draw.text((54, 32), "SMART CAMPUS  /  SIX VISUAL STORIES", font=title_font, fill=(245, 248, 249))
    draw.text((55, 75), "640 × 480 · 24-bit BMP · FAT32 SD-card gallery", font=small_font, fill=(161, 189, 204))
    for idx, im in enumerate(images):
        col, row = idx % 3, idx // 3
        x, y = 54 + col * 398, 128 + row * 365
        thumb = im.resize((360, 270), Image.Resampling.LANCZOS)
        sheet.paste(thumb, (x, y))
        draw.rounded_rectangle((x, y, x + 360, y + 270), radius=3, outline=(92, 122, 140), width=2)
        accent = rgb(SCENES[idx][4])
        draw.ellipse((x, y + 288, x + 9, y + 297), fill=accent)
        draw.text((x + 19, y + 283), f"IMG{idx + 1:03d}  ·  {SCENES[idx][0]}", font=small_font, fill=(238, 244, 245))
    out = root / "preview" / "contact_sheet.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out, format="PNG", optimize=True)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, default=None,
                        help="Output folder (default: assets/campus_media next to the repo root).")
    parser.add_argument("--font", type=str, default=None, help="Optional CJK TTF/TTC font path.")
    parser.add_argument("--skip-video", action="store_true", help="Only generate the BMP/PNG gallery.")
    args = parser.parse_args()

    global FONT_REGULAR, FONT_BOLD_PATH
    FONT_REGULAR = font_path(args.font)
    bold_candidates = [FONT_REGULAR.with_name("Dengb.ttf"), FONT_REGULAR.with_name("simhei.ttf"),
                       Path(r"C:\Windows\Fonts\Dengb.ttf"), Path(r"C:\Windows\Fonts\simhei.ttf")]
    FONT_BOLD_PATH = next((p for p in bold_candidates if p.is_file()), FONT_REGULAR)

    root = args.output_root or (Path(__file__).resolve().parents[1] / "assets" / "campus_media")
    sd_dir = root / "sd_card"
    preview_dir = root / "preview"
    sd_dir.mkdir(parents=True, exist_ok=True)
    preview_dir.mkdir(parents=True, exist_ok=True)

    images = []
    for idx, renderer in enumerate(SCENE_RENDERERS, 1):
        image = renderer().convert("RGB")
        bmp = sd_dir / f"IMG{idx:03d}.BMP"
        png = preview_dir / f"IMG{idx:03d}.png"
        save_bmp24(image, bmp)
        image.save(png, format="PNG", optimize=True)
        images.append(image)
        print(f"{bmp.name}: {image.width}x{image.height}, 24-bit BMP, {bmp.stat().st_size:,} bytes")

    contact = make_contact_sheet(images, root)
    print(f"Contact sheet: {contact}")
    if not args.skip_video:
        video = make_video(images, root)
        if video:
            print(f"Video: {video} ({video.stat().st_size:,} bytes)")
    print("Done. Copy only sd_card/IMG001.BMP through IMG006.BMP to the SD-card FAT32 root.")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
