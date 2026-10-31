#!/usr/bin/env python3
"""把 B1 字幕层渲染成 PNG 预览图。

【为什么需要这个脚本】
  仿真能证明"坐标换算正确""断言全过"，但证明不了"人看着舒不舒服"——
  字号够不够大、白字在照片上清不清楚、滚动标语排得好不好看，这些只能看图。
  本脚本直接从 RTL 源文件解析字模与字符表（不是从生成器的中间数据取），
  因此它渲染出来的就是综合进 FPGA 的那份数据；RTL 一改，预览图跟着变。

【做法】
  1. 解析 rtl/osd/osd_font8x16.v 的 `10'dN : pixels = 8'hXX;` 得到 41 个字形。
  2. 解析 rtl/osd/osd_strings.v 的 `10'dN : char_code = 7'hXX;` 得到字符表。
  3. 按 rtl/osd/osd_caption.v 的坐标表摆放，复现 '#'/'*' 序号替换与滚动偏移。
  4. 底图用渐变 + 亮暗块，用来检验"衬底压暗后白字是否仍然可读"。

用法:
  python scripts/render_caption_preview.py                 # 渲染默认相位
  python scripts/render_caption_preview.py --scroll 200    # 指定滚动偏移
  python scripts/render_caption_preview.py --out preview.png
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
FONT_V = ROOT / "rtl" / "osd" / "osd_font8x16.v"
STR_V = ROOT / "rtl" / "osd" / "osd_strings.v"

# ---- 与 osd_caption.v 保持一致的坐标表（改这里必须同步改 RTL）----
TITLE_Y0, TITLE_Y1 = 16, 31
TITLE_X0, TITLE_X1 = 32, 127
INDEX_Y0, INDEX_Y1 = 16, 31
INDEX_X0, INDEX_X1 = 576, 623
STATE_Y0, STATE_Y1 = 48, 63
STATE_X0, STATE_X1 = 32, 103
TICKER_Y0, TICKER_Y1 = 448, 463
TICKER_COLS = 64

# 与 video_overlay.v 一致的配色
COL_GLYPH = (0xF0, 0xF0, 0xF0)   # 字幕笔画
COL_GRID = (0x00, 0xFF, 0x00)    # 九宫格（用来对比"不抢层"）

# 字符串表行号（与 gen_osd_strings.py 的 LINE_* 一致）
LINE_TITLE = 0
LINE_INDEX = 1
LINE_PLAY, LINE_PAUSE, LINE_AUTO = 2, 3, 4
LINE_WAIT, LINE_EMERG, LINE_FAIL = 5, 6, 7
LINE_TICKER = 15


def parse_font(path: Path) -> dict[tuple[int, int], int]:
    """解析 `10'dN : pixels = 8'hXX;` → {(char_code, row): byte}"""
    text = path.read_text(encoding="utf-8", errors="replace")
    out: dict[tuple[int, int], int] = {}
    for m in re.finditer(
        r"10'd(\d+)\s*:\s*pixels\s*=\s*8'h([0-9A-Fa-f]{2})\s*;", text
    ):
        idx = int(m.group(1))
        out[(idx >> 4, idx & 0xF)] = int(m.group(2), 16)
    return out


def parse_strings(path: Path) -> dict[tuple[int, int], int]:
    """解析 `10'dN : char_code = 7'hXX;` → {(line, col): ascii}"""
    text = path.read_text(encoding="utf-8", errors="replace")
    out: dict[tuple[int, int], int] = {}
    for m in re.finditer(
        r"10'd(\d+)\s*:\s*char_code\s*=\s*7'h([0-9A-Fa-f]{2})\s*;", text
    ):
        idx = int(m.group(1))
        out[(idx >> 6, idx & 0x3F)] = int(m.group(2), 16)
    return out


def char_at(strings, line: int, col: int, index_val: int) -> int:
    """取字符码并做 '#'/'*' 替换（复现 osd_caption.v 的 rep_code 逻辑）"""
    code = strings.get((line, col), 0)
    if code == 0x23:                      # '#'
        return 0x30 + (index_val // 10)
    if code == 0x2A:                      # '*'
        return 0x30 + (index_val % 10)
    return code


def glyph_bit(font, code: int, row: int, bit: int) -> bool:
    """bit7 是最左像素，与 RTL 的 `glyph_px[~t_bit]` 等价"""
    byte = font.get((code & 0x3F, row), 0)
    return bool((byte >> (7 - bit)) & 1)


def make_background(w: int, h: int) -> Image.Image:
    """做一张"难为字幕"的底图：左亮右暗的渐变 + 明暗棋盘块。

    为什么不用纯色：纯色底看不出衬底压暗的作用，也看不出白字会不会在亮处糊掉。
    """
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            base = 200 - (x * 150) // w          # 左亮右暗
            band = ((x // 40) + (y // 40)) % 2
            v = base if band else base // 2
            px[x, y] = (v, max(0, v - 20), max(0, v - 45))
    return img


def darken(c: tuple[int, int, int], shift: int = 2) -> tuple[int, int, int]:
    """复现 `{2'b00, r[7:2], 2'b00, g[7:2], 2'b00, b[7:2]}`（压到 1/4）"""
    return tuple((v >> shift) << shift for v in c)  # type: ignore[return-value]


def render(font, strings, scroll: int, index_val: int, state_line: int) -> Image.Image:
    W, H = 640, 480
    img = make_background(W, H)
    d = ImageDraw.Draw(img)

    # ---- 1. 衬底压暗：先把四条带内像素压暗 ----
    for (y0, y1, x0, x1) in (
        (TITLE_Y0, TITLE_Y1, TITLE_X0, TITLE_X1),
        (INDEX_Y0, INDEX_Y1, INDEX_X0, INDEX_X1),
        (STATE_Y0, STATE_Y1, STATE_X0, STATE_X1),
        (TICKER_Y0, TICKER_Y1, 0, W - 1),
    ):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                img.putpixel((x, y), darken(img.getpixel((x, y))))

    # ---- 2. 画四处文字 ----
    def draw_text(line: int, y0: int, x0: int, cols: int, rolling: bool = False):
        """画一行文字。

        滚动分支必须**逐像素**算列号与列内偏移，不能"一格 8 像素共用一个列号"：
        滚动偏移不是 8 的整数倍时，屏幕上每一格会横跨两个字符（前一字符的尾部
        加上后一字符的头部）。RTL 里 `ticker_src = active_x + scroll_px` 然后
        分别取 [8:3] 与 [2:0]，每个像素各算各的，天然跨字符正确 ——
        预览脚本若按格近似，就会渲染出字模表里找不到的"半个字"。
        """
        for cx in range(cols):
            for gy in range(16):
                for gx in range(8):
                    px_x = x0 + cx * 8 + gx
                    if not (0 <= px_x < W):
                        continue
                    if rolling:
                        src = px_x + scroll
                        col = (src & 0x1FF) >> 3
                        bit = src & 0x7
                    else:
                        col = cx
                        bit = gx
                    code = char_at(strings, line, col, index_val)
                    if code == 0:
                        continue
                    if glyph_bit(font, code, gy, bit):
                        img.putpixel((px_x, y0 + gy), COL_GLYPH)

    draw_text(LINE_TITLE, TITLE_Y0, TITLE_X0, (TITLE_X1 - TITLE_X0 + 1) // 8)
    draw_text(LINE_INDEX, INDEX_Y0, INDEX_X0, (INDEX_X1 - INDEX_X0 + 1) // 8)
    draw_text(state_line, STATE_Y0, STATE_X0, (STATE_X1 - STATE_X0 + 1) // 8)
    # 标语是**全宽** 640 像素（RTL 里 ticker_band 覆盖 active_x ∈ [0,639]），
    #   而字符表周期只有 64 列 = 512 像素。所以要画 640/8 = 80 格，
    #   多出的 16 格靠列号取模回到表头 —— 与 RTL 的 `ticker_src[8:3]` 一致。
    draw_text(LINE_TICKER, TICKER_Y0, 0, W // 8, rolling=True)

    # ---- 3. 九宫格参考线（证明字幕层不抢它的层）----
    for gx in (213, 426):
        d.line([(gx, 0), (gx, H - 1)], fill=COL_GRID)
    for gy in (160, 320):
        d.line([(0, gy), (W - 1, gy)], fill=COL_GRID)

    return img


def main() -> int:
    ap = argparse.ArgumentParser(description="渲染 B1 字幕层预览图")
    ap.add_argument("--scroll", type=int, default=0, help="滚动偏移 0..511")
    ap.add_argument("--index", type=int, default=7, help="页面序号 0..31")
    ap.add_argument("--state", type=str, default="PLAY",
                    choices=["PLAY", "PAUSE", "AUTO", "WAITING", "EMERGENCY", "FAIL"])
    ap.add_argument("--out", type=str, default="reports/caption_preview.png")
    args = ap.parse_args()

    if not FONT_V.exists() or not STR_V.exists():
        print(f"找不到 RTL 源: {FONT_V} / {STR_V}")
        return 1

    font = parse_font(FONT_V)
    strings = parse_strings(STR_V)
    print(f"字模: {len(font)} 项 = {len(font) // 16} 个字形")
    print(f"字符表: {len(strings)} 项（非空格）")

    state_map = {
        "PLAY": LINE_PLAY, "PAUSE": LINE_PAUSE, "AUTO": LINE_AUTO,
        "WAITING": LINE_WAIT, "EMERGENCY": LINE_EMERG, "FAIL": LINE_FAIL,
    }
    img = render(font, strings, args.scroll & 0x1FF, args.index, state_map[args.state])

    out = Path(args.out)
    if not out.is_absolute():
        out = ROOT / out
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out)
    print(f"written: {out.relative_to(ROOT)}  (scroll={args.scroll}, index={args.index}, state={args.state})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
