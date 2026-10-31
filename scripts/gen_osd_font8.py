#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 rtl/osd/osd_font8x16.v —— 8x16 点阵字模 ROM（字幕专用字符集）。

为什么是 8x16 而不是 8x8
------------------------
先试过 8x8：Consolas Bold 缩到 8x8 后 'A' 糊成一个实心块，'B'/'D'/'8'
互相难分，字幕读不出来。8x16 是经典 VGA 文本模式的规格，笔画能拉开，
字母轮廓清晰，是 640x480 上单行字幕的合适粒度。

为什么字符集只有 41 个
----------------------
字幕内容 = 标题 + 播放状态 + 页面序号 + 滚动标语，全部用**大写字母、
数字和几个标点**表达（中文由 science_page 承担，字幕不重复）。
只收录实际用到的 41 个字符，ROM 从 95 个可打印 ASCII 砍到 41 个，
综合后的 LUT 代价大约减半——本项目 LUT 余量只剩三成，这个裁剪是必要的。

    ' '            0x20
    '-' '.' '/'    0x2D 0x2E 0x2F
    '0'..'9'       0x30..0x39
    ':'            0x3A
    'A'..'Z'       0x41..0x5A

为什么 ROM 索引直接用 char_code[5:0]
-----------------------------------
上面 41 个字符全部落在 ASCII 0x20..0x5F 这一段，**低 6 位互不相同**，
所以 RTL 端 `rom_index = char_code[5:0]` 即可，不需要减法、不需要比较、
不需要字符映射表。表里按 `{char_code[5:0], row}` 排列，未收录的索引
走 default 输出全黑（显示为空白），不会画出乱码。

字形来源
--------
栅格化自 Consolas Bold（Windows 系统字体）。本工程只分发栅格化后的
点阵常量，运行时**不加载任何字体文件**。

用法
----
    python scripts/gen_osd_font8.py            # 打印 ASCII art 供目视核对
    python scripts/gen_osd_font8.py --emit     # 写出 rtl/osd/osd_font8x16.v
"""
import argparse
import os
import sys

from PIL import Image, ImageDraw, ImageFont

# ---- 字形栅格参数（经目视比对选定，见模块注释）----
FONT_PATH = r"C:\Windows\Fonts\consolab.ttf"   # Consolas Bold
FONT_SIZE = 14         # 8x16 格子下字形高 9 行，笔画清晰不粘连
BASE_Y = 12            # 基线 y（anchor="ms" 的 s = baseline），上方留 3 行
CELL_W = 8
CELL_H = 16
THRESHOLD = 100        # 抗锯齿灰度二值化阈值（0..255）

# 字幕实际使用的 41 个字符（顺序无关，表按 ascii & 0x3F 排序输出）
CHARSET = (
    [" "] +
    ["-", ".", "/"] +
    [chr(c) for c in range(0x30, 0x3A)] +   # 0-9
    [":"] +
    [chr(c) for c in range(0x41, 0x5B)]     # A-Z
)


def render_cell(font, ch):
    """把一个字符渲染成 16 行 x 8 列的 0/1 列表（每行一个 8 bit 整数）。"""
    img = Image.new("L", (CELL_W, CELL_H), 0)
    draw = ImageDraw.Draw(img)
    # anchor="ms": 水平居中、垂直以基线对齐，避免逐字符手工调偏移
    draw.text((CELL_W // 2, BASE_Y), ch, font=font, fill=255, anchor="ms")
    px = img.load()
    rows = []
    for y in range(CELL_H):
        bits = 0
        for x in range(CELL_W):
            if px[x, y] >= THRESHOLD:
                bits |= 1 << (CELL_W - 1 - x)   # 最左像素是 MSB
        rows.append(bits)
    return rows


def build_table():
    """返回 {rom_index: (字符, [16 行位图])}，rom_index = ascii & 0x3F。"""
    if not os.path.exists(FONT_PATH):
        sys.exit("找不到字体: " + FONT_PATH)
    font = ImageFont.truetype(FONT_PATH, FONT_SIZE)
    table = {}
    for ch in CHARSET:
        table[ord(ch) & 0x3F] = (ch, render_cell(font, ch))
    return table


def print_art(table):
    """打印 ASCII art，供人眼确认字形没糊、没切边。"""
    for idx in sorted(table):
        ch, rows = table[idx]
        label = ch if ch != " " else "<sp>"
        print("idx %2d  ascii 0x%02X  '%s'" % (idx, ord(ch), label))
        for bits in rows:
            line = "".join("#" if (bits >> (7 - x)) & 1 else "." for x in range(8))
            print("    " + line)
        print("")


def emit_verilog(table, out_path):
    lines = []
    a = lines.append
    a("// ============================================================================")
    a("// 文件名  : osd_font8x16.v")
    a("// 所在位置: rtl/osd/osd_font8x16.v")
    a("// 所属层次: OSD 层 / 8x16 点阵字模 ROM")
    a("// 作者    : 智播校园项目组")
    a("// ============================================================================")
    a("// 【一】系统功能")
    a("//   智播校园把 SD 卡图片送上 HDMI。B1 扩展项要求\"图层叠加与字幕\"，")
    a("//   字幕必须是**真字符**——旧的 12 格方块位图只能表示二进制状态，")
    a("//   拼不出\"PLAY\"\"IMG 05/12\"这种文字。")
    a("//   本模块是字幕通路的第一级: 给字符码和行号，返回该行 8 个像素。")
    a("")
    a("// 【二】本模块功能")
    a("//   输入 char_code[5:0] + row[3:0] → 输出 pixels[7:0]（bit7 = 最左像素）")
    a("//   纯组合，无时钟、无状态、同拍出图。")
    a("")
    a("// 【三】为什么索引是 char_code[5:0] 而不是 char_code-0x20")
    a("//   本 ROM 收录的字符集（空格、'-' '.' '/'、'0'-'9'、':'、'A'-'Z'）")
    a("//   全部落在 ASCII 0x20..0x5F，**低 6 位互不相同**:")
    a("//       ' '(0x20) -> 低6位 32      '@'(0x40) -> 低6位 0")
    a("//       'A'(0x41) -> 低6位 1       'Z'(0x5A) -> 低6位 26")
    a("//   所以上层把字符码低 6 位直接接进来即可，**省掉一个减法器**。")
    a("//   未收录的索引走 default 输出 0x00，屏幕上表现为空白而不是乱码。")
    a("")
    a("// 【四】为什么是 8x16 而不是 8x8")
    a("//   实测 8x8 下 'A' 糊成实心块、'B'/'D'/'8' 互相难分，字幕读不出来。")
    a("//   8x16 是经典 VGA 文本模式规格，笔画能拉开，是 640x480 单行字幕的")
    a("//   合适粒度。代价是每字形 16 行常量，但字符集只有 41 个，总量可控。")
    a("")
    a("// 【五】字形来源与许可")
    a("//   点阵由 scripts/gen_osd_font8.py 从 Consolas Bold 栅格化生成后固化")
    a("//   为本 ROM；运行时**不加载任何字体文件**。")
    a("//   重新生成: python scripts/gen_osd_font8.py --emit")
    a("")
    a("// 【六】资源代价")
    a("//   41 字形 x 16 行 x 8 bit = 5248 bit 常量，综合成 LUT 查表。")
    a("//   不用 BRAM: BRAM 读延迟 1 拍，而字幕必须与像素同拍组合出图。")
    a("// ============================================================================")
    a("module osd_font8x16 (")
    a("    input  wire [5:0] char_code,   // 字符码低 6 位（ASCII & 0x3F）")
    a("    input  wire [3:0] row,         // 字形行号 0..15（0 = 最上一行）")
    a("    output reg  [7:0] pixels       // 该行 8 个像素，bit7 = 最左")
    a(");")
    a("")
    a("    // 一项 = {字符低6位, 行号} 共 10 bit；未列出的组合输出 0x00")
    a("    always @(*) begin")
    a("        pixels = 8'h00;            // 默认空白（未收录字符显示为空）")
    a("        case ({char_code, row})")
    for idx in sorted(table):
        ch, rows = table[idx]
        label = ch if ch != " " else "space"
        a("            // %-2d: '%s'" % (idx, label))
        for y, bits in enumerate(rows):
            key = (idx << 4) | y
            a("            10'd%-3d: pixels = 8'h%02X;" % (key, bits))
    a("            default: pixels = 8'h00;")
    a("        endcase")
    a("    end")
    a("")
    a("endmodule")
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("written: %s (%d lines, %d glyphs)" % (out_path, len(lines), len(table)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emit", action="store_true", help="写出 osd_font8x16.v")
    ap.add_argument("--art", action="store_true", help="打印 ASCII art")
    args = ap.parse_args()
    table = build_table()
    if args.art or not args.emit:
        print_art(table)
    if args.emit:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        emit_verilog(table, os.path.join(root, "rtl", "osd", "osd_font8x16.v"))


if __name__ == "__main__":
    main()
