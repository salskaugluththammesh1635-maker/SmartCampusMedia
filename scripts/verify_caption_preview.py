#!/usr/bin/env python3
"""校验 B1 字幕预览图，分两项：

【一、静态三条带 OCR】
  把 PNG 的像素按 8×16 网格切回字形，再在 RTL 字模表里找唯一匹配 ——
  相当于对预览图做一次 OCR，判据是"能不能在 41 个字形里找到唯一匹配"。
  匹配不上就说明渲染管线（坐标/替换）和 RTL 数据不一致。

【二、标语滚动位移不变性】
  滚动不做 OCR。滚动偏移不是 8 的整数倍时，屏幕上同一格会横跨两个字符，
  按格切分读出来的是字模表里不存在的图案 —— 那是校验方法的问题，不是 RTL 的。
  改用纯像素级不变量：把整条标语平移 scroll 像素后，必须与 scroll=0 的画面
  逐像素重合（在 512 像素周期内取模）。这条比 OCR 更强 —— 它不关心"字是什么"，
  只要求"滚 N 像素 = 真的平移了 N 像素"，任何错位都会失败。

用法:
  python scripts/verify_caption_preview.py                       # 校验默认两张图
  python scripts/verify_caption_preview.py --png a.png --scroll 0
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
FONT_V = ROOT / "rtl" / "osd" / "osd_font8x16.v"

TITLE_Y0, TITLE_X0 = 16, 32
INDEX_Y0, INDEX_X0 = 16, 576
STATE_Y0, STATE_X0 = 48, 32
TICKER_Y0 = 448
TICKER_PERIOD = 512          # scroll_px 的位宽决定: 9 bit → 512 像素一整轮
GLYPH = (0xF0, 0xF0, 0xF0)


def parse_font(path: Path) -> dict[int, list[int]]:
    """{rom_index: [16 行的 byte]}

    注意: 键是 ROM 索引（= char_code & 0x3F），不是 ASCII。
    字模表按 `rom_index = ord(ch) & 0x3F` 排布：索引 0..31 对应 ASCII 0x40..0x5F，
    32..63 对应 ASCII 0x20..0x3F。
    """
    text = path.read_text(encoding="utf-8", errors="replace")
    out: dict[int, list[int]] = {}
    for m in re.finditer(r"10'd(\d+)\s*:\s*pixels\s*=\s*8'h([0-9A-Fa-f]{2})\s*;", text):
        idx, val = int(m.group(1)), int(m.group(2), 16)
        code, row = idx >> 4, idx & 0xF
        out.setdefault(code, [0] * 16)[row] = val
    return out


def rom_index_to_ascii(idx: int) -> int:
    """ROM 索引 → ASCII（与 RTL 端 `char_code[5:0]` 的排布互逆）"""
    return idx + 0x40 if idx < 32 else idx


def read_glyph(px, x0: int, y0: int) -> list[int]:
    """从 PNG 取 8×16 网格，还原成 16 个 byte（bit7 = 最左）"""
    rows = []
    for gy in range(16):
        b = 0
        for gx in range(8):
            if px[x0 + gx, y0 + gy] == GLYPH:
                b |= 1 << (7 - gx)
        rows.append(b)
    return rows


def identify(font: dict[int, list[int]], rows: list[int]) -> str:
    """在字模表里找唯一匹配；空白返回 ' '，无匹配返回 '?'"""
    if not any(rows):
        return " "
    hits = [c for c, pat in font.items() if pat == rows]
    if not hits:
        return "?"
    if len(hits) > 1:
        print(f"  [注意] {len(hits)} 个字形点阵相同: "
              f"{[chr(rom_index_to_ascii(h)) for h in hits]}", file=sys.stderr)
    return chr(rom_index_to_ascii(hits[0]))


def ocr_bands(path: Path, font, cols: int) -> int:
    """对三条静态带做 OCR，返回失配数"""
    img = Image.open(path).convert("RGB")
    px = img.load()
    print(f"图: {path.name}  {img.width}x{img.height}")
    print(f"字模表: {len(font)} 个字形\n")

    bad = 0
    for name, y0, x0, ncol in (
        ("标题", TITLE_Y0, TITLE_X0, cols),
        ("序号", INDEX_Y0, INDEX_X0, 6),
        ("状态", STATE_Y0, STATE_X0, cols),
    ):
        s = "".join(identify(font, read_glyph(px, x0 + i * 8, y0)) for i in range(ncol))
        flag = "" if "?" not in s else "   <-- 有无法识别的字形"
        if "?" in s:
            bad += s.count("?")
        print(f"{name}  [{y0},{x0}] -> |{s}|{flag}")
    return bad


def ticker_shift_check(png_a: Path, scroll_a: int, png_b: Path, scroll_b: int) -> int:
    """标语滚动位移不变性：B 的笔画像素必须落在 A 平移 (scroll_b-scroll_a) 后的笔画位置

    逐像素比对整条标语带（y ∈ [448,463] × x ∈ [0,639]）。
    取模周期是 512 像素，因为 scroll_px 是 9 bit、64 字符 × 8 像素 = 512。

    **只比对笔画像素（GLYPH 色），不比对背景。**
    为什么：衬底压暗作用于底图，而底图不随滚动平移 —— 拿背景一起比，比的是
    "底图有没有平移"，那是错的参照。滚动要证明的是"字滚了 N 像素"，
    所以只需要"B 的字形掩码 == A 的字形掩码平移 N"。
    """
    a = Image.open(png_a).convert("RGB").load()
    b = Image.open(png_b).convert("RGB").load()
    delta = scroll_b - scroll_a

    bad = 0
    total = 0
    skipped = 0
    for y in range(TICKER_Y0, TICKER_Y0 + 16):
        for x in range(0, 640):
            # 跳过九宫格竖线所在的列：预览脚本为了展示"字幕不抢九宫格的层"
            #   在 213/426 画了绿色参考线，它穿过标语带、且不随滚动平移。
            #   那 2 列是叠加层的像素，不属于字幕，拿来做滚动比对是错误参照。
            if x in (213, 426):
                skipped += 1
                continue
            src_x = (x + delta) % TICKER_PERIOD
            if src_x >= 640:
                continue          # 超出 A 的采样范围，无法比对
            if src_x in (213, 426):
                skipped += 1
                continue
            total += 1
            # 只比"是不是笔画"这一个布尔量
            if (b[x, y] == GLYPH) != (a[src_x, y] == GLYPH):
                bad += 1

    print(f"\n滚动位移不变性: A(scroll={scroll_a}) -> B(scroll={scroll_b})，"
          f"平移 {delta} 像素")
    print(f"  比对 {total} 个像素（只比笔画掩码，不比底图；跳过九宫格竖线 {skipped} 个），"
          f"失配 {bad} 个")
    return bad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--png", default="reports/caption_preview.png")
    ap.add_argument("--png2", default="reports/caption_preview_scroll.png")
    ap.add_argument("--scroll", type=int, default=0)
    ap.add_argument("--scroll2", type=int, default=180)
    ap.add_argument("--cols", type=int, default=12)
    args = ap.parse_args()

    p1 = Path(args.png) if Path(args.png).is_absolute() else ROOT / args.png
    p2 = Path(args.png2) if Path(args.png2).is_absolute() else ROOT / args.png2
    font = parse_font(FONT_V)

    total_bad = 0
    # 静态三条带：只对 scroll=0 的图做 OCR（滚动图按格切分读不出正确结果）
    if args.scroll % 8 == 0:
        total_bad += ocr_bands(p1, font, args.cols)
    else:
        print(f"[跳过 OCR] scroll={args.scroll} 不是 8 的整数倍，按格切分不可靠")

    missing_scroll_image = not p2.is_file()
    if not missing_scroll_image:
        total_bad += ticker_shift_check(p1, args.scroll, p2, args.scroll2)
    else:
        print(f"\n[缺失滚动校验输入] 找不到 {p2}")

    print()
    if total_bad:
        print(f"CAPTION PREVIEW MISMATCH: {total_bad} 处不一致")
    if missing_scroll_image:
        print("CAPTION PREVIEW FAILED: 滚动对比图是必需输入")
        return 1
    if total_bad:
        return 1
    print("CAPTION PREVIEW OK: 全部一致")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
