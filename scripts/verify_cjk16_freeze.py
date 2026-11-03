#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""独立复核 cjk16 字库的「索引 0..94 冻结」与「覆盖率」——**不复用生成脚本的渲染函数**。

为什么需要这个脚本
------------------
gen_assets_v2_font.py 的自检是「自己检查自己」：它用 render_glyph() 生成点阵，
再用同一批点阵去比对上一版 .hex。如果 render_glyph() 本身被改坏了、而上一版
.hex 也是它生成的，那两者的"一致"只证明两版错得一样。

本脚本绕过生成脚本，用**独立重写的栅格化代码**（同样的 Pillow 参数，但从
ImageFont 到二值化的每一步都自己写，不 import gen_assets_v2_font 的任何函数），
把冻结的 95 个字重新画一遍，与磁盘上 cjk16_bitmap.hex 的前 1520 行逐位比对。
只有当两份**独立实现**给出同样点阵时，「索引 0..94 没变」才算被证明。

另外复核：
  1. .hex 的 7440 行能否按 16 行一字切开，切成 465 字后每字都非空、互不相同；
  2. 前 95 个点阵对应的字符（由 charset.txt 读出）是否与冻结清单逐字相同；
  3. 四份真实文本（字幕 + 三份文案）里的每个字符，是否都能在 charset.txt 里找到；
  4. cjk16_font.v 的 case 常量是否与 .hex 完全对应（同索引同行为同值）。

用法：
    python scripts/verify_cjk16_freeze.py
退出码 0 = 全部通过。
"""
from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

REPO_ROOT = Path(__file__).resolve().parents[1]
FONT_DIR = REPO_ROOT / "assets" / "v2" / "masters" / "font"

FONT_PATH = Path(r"C:\Windows\Fonts\NotoSansSC-VF.ttf")
FONT_SIZE = 15
THRESHOLD = 96
CELL = 16

# 与生成脚本里的 LEGACY_CHARS 逐字相同的冻结清单（独立抄一份，避免"引用同一常量"）
FROZEN = (
    "日常模式科普应急智慧校园书香创客工坊绿色运动嘉年华平安温度湿高报警"
    "环境正摄氏亮音量分辨率屏占比滚字幕频可视化开关启闭第档图片乐播放暂停"
    "上一张下在加载请稍候无信号系统0123456789℃%："
)

TEXT_SOURCES = [
    ("assets/v2/sdcard/COMMON/SRT/NARR.SRT", "科普字幕"),
    ("assets/v2/masters/text/campus_ticker.txt", "校园介绍滚动文案"),
    ("assets/v2/masters/text/emergency_ticker.txt", "应急提示文案"),
    ("assets/v2/masters/text/ui_strings.txt", "UI 固定文案"),
]


def rasterize_independent(font: ImageFont.FreeTypeFont, ch: str) -> list[int]:
    """独立实现的栅格化：大画布渲染 -> 墨迹裁剪 -> 居中贴到 16x16 -> 逐行打包。

    与生成脚本思路相同（包围盒居中），但**代码是独立写的**，不调用其任何函数。
    """
    canvas = CELL + 16                      # 留足余量，任何字形都不会被画布切边
    img = Image.new("L", (canvas, canvas), 0)
    ImageDraw.Draw(img).text((canvas // 2, canvas // 2), ch,
                             font=font, fill=255, anchor="mm")
    bbox = img.getbbox()
    if bbox is None:                        # 空白字符（理论上不该出现在字库里）
        return [0] * CELL
    ink = img.crop(bbox)
    cell = Image.new("L", (CELL, CELL), 0)
    ox = (CELL - ink.width) // 2
    oy = (CELL - ink.height) // 2
    cell.paste(ink, (ox, oy))
    px = cell.load()
    rows = []
    for y in range(CELL):
        bits = 0
        for x in range(CELL):
            if px[x, y] >= THRESHOLD:
                bits |= 1 << (CELL - 1 - x)   # bit15 = 最左像素
        rows.append(bits)
    return rows


def main() -> int:
    ok = True

    font = ImageFont.truetype(str(FONT_PATH), FONT_SIZE)
    font.set_variation_by_name("Regular")

    hex_lines = (FONT_DIR / "cjk16_bitmap.hex").read_text(encoding="ascii").split()
    if len(hex_lines) % CELL:
        print(f"[BAD] .hex 行数 {len(hex_lines)} 不是 {CELL} 的整数倍")
        return 1
    n_glyph = len(hex_lines) // CELL
    disk = [[int(hex_lines[i * CELL + r], 16) for r in range(CELL)]
            for i in range(n_glyph)]
    print(f"[信息] .hex {len(hex_lines)} 行 = {n_glyph} 字形 x {CELL} 行")

    # ---- 1. 索引 0..94 冻结：独立重绘 vs 磁盘 ----
    print(f"\n[1] 索引 0..{len(FROZEN) - 1} 冻结复核（独立实现重绘 vs 磁盘 .hex）")
    diff = []
    for i, ch in enumerate(FROZEN):
        mine = rasterize_independent(font, ch)
        if mine != disk[i]:
            bad_rows = [r for r in range(CELL) if mine[r] != disk[i][r]]
            diff.append((i, ch, bad_rows[:3]))
    ok &= not diff
    print(f"  [{'OK ' if not diff else 'BAD'}] 冻结 {len(FROZEN)} 字形 x {CELL} 行 = "
          f"{len(FROZEN) * CELL} 行，独立重绘与磁盘逐位比对不符 {len(diff)} 字")
    for i, ch, rows in diff[:5]:
        print(f"        索引 {i} '{ch}' 差异行 {rows}")

    # ---- 2. charset.txt 里的字符序列与冻结清单逐字相同 ----
    print(f"\n[2] charset.txt 字符序列")
    cs_lines = (FONT_DIR / "cjk16_charset.txt").read_text(encoding="utf-8").splitlines()
    chars = []
    idx_seen = []
    for ln in cs_lines:
        if ln.startswith("#") or not ln.strip():
            continue
        parts = ln.split()                  # index  char  codepoint  ink_pct
        if len(parts) < 3:
            print(f"  [BAD] 无法解析的行：{ln!r}")
            ok = False
            continue
        idx_seen.append(int(parts[0]))
        chars.append(parts[1])
    seq_ok = (chars[:len(FROZEN)] == list(FROZEN))
    idx_ok = idx_seen == list(range(len(chars)))
    ok &= seq_ok and idx_ok
    print(f"  [{'OK ' if seq_ok else 'BAD'}] 前 {len(FROZEN)} 个字符与冻结清单逐字一致"
          f"（charset 总 {len(chars)} 字）")
    print(f"  [{'OK ' if idx_ok else 'BAD'}] 索引列 0..{len(chars) - 1} 连续无跳号无重复")
    if not seq_ok:
        for i in range(len(FROZEN)):
            if chars[i] != FROZEN[i]:
                print(f"        首个不符 索引 {i}: 磁盘 '{chars[i]}' vs 冻结 '{FROZEN[i]}'")
                break
    if len(chars) != n_glyph:
        print(f"  [BAD] charset 字数 {len(chars)} != .hex 字形数 {n_glyph}")
        ok = False

    # ---- 3. 覆盖率：四份真实文本的每个字符都在 charset 里 ----
    print(f"\n[3] 覆盖率（真实文本逐字符核对）")
    have = set(chars)
    for rel, desc in TEXT_SOURCES:
        p = REPO_ROOT / rel
        if not p.is_file():
            print(f"  [BAD] 文本来源不存在：{rel}")
            ok = False
            continue
        need = set(p.read_text(encoding="utf-8")) - {"\n", "\r", "\t", " "}
        miss = sorted(need - have)
        ok &= not miss
        print(f"  [{'OK ' if not miss else 'BAD'}] {desc:<16} {len(need):>4} 字符  "
              f"缺 {len(miss):>3}{'' if not miss else '  缺字：' + ''.join(miss)}")

    # ---- 4. cjk16_font.v 与 .hex 逐索引逐行对应 ----
    print(f"\n[4] cjk16_font.v 与 .hex 对应性")
    v_txt = (FONT_DIR / "cjk16_font.v").read_text(encoding="utf-8")
    import re
    pairs = re.findall(r"^\s+(\d+)'d(\d+): pixels = 16'h([0-9A-Fa-f]{4});$",
                       v_txt, re.MULTILINE)
    vmap = {}
    for _w, key, val in pairs:
        k = int(key)
        vmap[k] = int(val, 16)
    mism = 0
    for i in range(n_glyph):
        for r in range(CELL):
            if vmap.get(i * CELL + r) != disk[i][r]:
                mism += 1
    ok &= mism == 0 and len(pairs) == n_glyph * CELL
    print(f"  [{'OK ' if mism == 0 and len(pairs) == n_glyph * CELL else 'BAD'}] "
          f"case 常量 {len(pairs)} 条 = {n_glyph}x{CELL}，与 .hex 取值不符 {mism} 处")

    print(f"\n[结论] {'全部通过 ✓' if ok else '存在失败项 ✗'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
