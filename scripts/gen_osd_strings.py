#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 rtl/osd/osd_strings.v —— 字幕字符串常量表。

为什么用脚本生成而不是手写
--------------------------
字符串表要按 {line_sel, col} 展开成 case 项，列号一旦数错一个字符，
整行字幕就整体错位，而错位在综合和仿真里都不会报错——只有上板看画面
才发现。用脚本按字符串自动展开列号，把"数错列"这个错误源直接消灭。

表的结构（16 行 x 64 列）
-------------------------
    行  0  "SMART CAMPUS"     标题
    行  1  "IMG #*"           页面序号（# = 十位, * = 个位）
    行  2  "PLAY"             状态: 播放中
    行  3  "PAUSE"            状态: 暂停
    行  4  "AUTO"             状态: 自动轮播
    行  5  "WAITING"          状态: 加载中
    行  6  "EMERGENCY"        状态: 应急
    行  7  "FAIL"             状态: 读图失败
    行 8..14  (空, 预留)
    行 15  64 字符滚动标语

为什么是 16 行而不是 8 行
-------------------------
line_sel 8 行时，标题、序号、5 个状态、标语正好占满，再想加一行状态
（比如 FAIL）就得挤掉别的。扩到 4 bit / 16 行，多出的行**不占任何硬件**
——case 项只列非空格字符，空行在综合后直接消失。代价为零，换来的是
以后加文案不用重排。

占位符
------
    '#'  -> 动态计数的高位数字（十位）
    '*'  -> 动态计数的低位数字（个位）
    这两个字符**故意不在字模 ROM 的字符集内**（ROM 只收录空格、'-' '.' '/'、
    '0'-'9'、':'、'A'-'Z'），所以即使替换逻辑失效，它们也只会显示成空白，
    不会画出乱码。RTL 端把它们替换成 '0'+digit 再送字模 ROM。

为什么滚动标语正好 64 字符
--------------------------
滚动用 `col = (像素列 + 滚动偏移) & 6'b111111` 实现，64 = 2^6 是位掩码，
取模零成本。标语不足 64 字符时脚本自动用空格补齐。

用法
----
    python scripts/gen_osd_strings.py --emit     # 写出 rtl/osd/osd_strings.v
    python scripts/gen_osd_strings.py --show     # 打印每行的列布局
"""
import argparse
import os

TOTAL_LINES = 16      # line_sel 位宽 = 4
TICKER_LINE = 15      # 滚动标语固定放最后一行
TICKER_COLS = 64      # 滚动行循环列数（必须 2 的幂）
STATIC_COLS = 16      # 非滚动行最大字符数（16 字符 = 128 像素）

# ---- 字幕文本（改动这里即可换文案，然后重新 --emit）----
TEXT = {
    0: "SMART CAMPUS",       # 标题
    1: "IMG #*",             # 页面序号
    2: "PLAY",               # 状态: 播放中
    3: "PAUSE",              # 状态: 暂停
    4: "AUTO",               # 状态: 自动轮播
    5: "WAITING",            # 状态: 加载中
    6: "EMERGENCY",          # 状态: 应急
    7: "FAIL",               # 状态: 读图失败
}

# 滚动标语。不足 64 字符时脚本自动用空格右补齐——人手数 64 个空格必错，
# 交给脚本算。超过 64 字符则报错（会绕回覆盖开头）。
TICKER_RAW = "SMART CAMPUS MEDIA CENTER  --  WELCOME  --  ONLINE  NOW"


def build_lines():
    """展开成 16 行定长列表，空行是空串。"""
    lines = []
    for i in range(TOTAL_LINES):
        if i == TICKER_LINE:
            lines.append(TICKER_RAW + " " * (TICKER_COLS - len(TICKER_RAW)))
        else:
            lines.append(TEXT.get(i, ""))
    return lines


def check(lines):
    """在生成前把能提前发现的错误全部挡掉。"""
    if len(TICKER_RAW) > TICKER_COLS:
        raise SystemExit("滚动标语超过 %d 字符（当前 %d），会绕回覆盖开头: %r"
                         % (TICKER_COLS, len(TICKER_RAW), TICKER_RAW))
    allowed = set(" -./0123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZ#*")
    for i, line in enumerate(lines):
        bad = sorted(set(line) - allowed)
        if bad:
            raise SystemExit("行 %d 含有字模 ROM 不支持且不是占位符的字符: %r"
                             % (i, bad))
        limit = TICKER_COLS if i == TICKER_LINE else STATIC_COLS
        if len(line) > limit:
            raise SystemExit("行 %d 长 %d 字符，超过上限 %d: %r"
                             % (i, len(line), limit, line))


def show(lines):
    for i, line in enumerate(lines):
        if not line.strip():
            print("line %2d  (empty)" % i)
            continue
        print("line %2d  (%2d chars): %r" % (i, len(line), line))
        print("          " + "".join(str(c % 10) for c in range(len(line))))


def emit_verilog(out_path, lines):
    a = []
    w = a.append
    w("// ============================================================================")
    w("// 文件名  : osd_strings.v")
    w("// 所在位置: rtl/osd/osd_strings.v")
    w("// 所属层次: OSD 层 / 字幕字符串常量表")
    w("// 作者    : 智播校园项目组")
    w("// 自动生成: 由 scripts/gen_osd_strings.py 生成，请勿手工编辑")
    w("// ============================================================================")
    w("// 【一】系统功能")
    w("//   B1 扩展项\"图层叠加与字幕\"要求屏幕上有标题、页面序号、播放状态和")
    w("//   滚动标语。这些文字本身是常量，真正随运行变化的只有序号数字，")
    w("//   所以把文案做成一张只读表，渲染器按坐标查表即可。")
    w("")
    w("// 【二】本模块功能")
    w("//   输入 {line_sel[3:0], col[5:0]} → 输出 char_code[6:0]（ASCII）")
    w("//   纯组合，无时钟。未定义位置输出 0x00（NUL），渲染器据此判定\"无字\"。")
    w("")
    w("// 【三】表的排列")
    w("//   地址 = {line_sel, col}，共 10 bit。只列出**非空格**字符，空格由")
    w("//   默认值 0x00 承担——这样 case 项数从 16x64 降到实际字符数，")
    w("//   综合后是一张小 LUT 表而不是大 ROM。空行在综合后完全消失。")
    w("//")
    w("//   行  0  SM-TITLE    \"SMART CAMPUS\"      标题")
    w("//   行  1  SM-INDEX    \"IMG #*\"            页面序号（# 十位, * 个位）")
    w("//   行  2  SM-PLAY     \"PLAY\"              播放中")
    w("//   行  3  SM-PAUSE    \"PAUSE\"             暂停")
    w("//   行  4  SM-AUTO     \"AUTO\"              自动轮播")
    w("//   行  5  SM-WAIT     \"WAITING\"           加载中")
    w("//   行  6  SM-EMERG    \"EMERGENCY\"         应急")
    w("//   行  7  SM-FAIL     \"FAIL\"              读图失败")
    w("//   行  8..14          （空，预留）")
    w("//   行 15  SM-TICKER   64 字符滚动标语")
    w("")
    w("// 【四】占位符 # 与 *")
    w("//   这两个字符不在字模 ROM 的字符集内（ROM 只收录空格、'-' '.' '/'、")
    w("//   '0'-'9'、':'、'A'-'Z'）。渲染器把 '#' 换成序号十位、'*' 换成")
    w("//   个位后再送 ROM。若替换逻辑失效，ROM 查不到这两个码，只会输出")
    w("//   空白，**不会画出乱码**——这是有意选的\"失败安全\"字符。")
    w("")
    w("// 【五】滚动标语的 64 列")
    w("//   滚动用 `col = (像素列 + 滚动偏移) & 6'b111111` 实现，64 = 2^6，")
    w("//   取模是位掩码，零逻辑成本。标语因此必须正好 64 字符。")
    w("// ============================================================================")
    w("module osd_strings (")
    w("    input  wire [3:0] line_sel,    // 文本行 0..15")
    w("    input  wire [5:0] col,         // 字符列 0..63")
    w("    output reg  [6:0] char_code    // 该位置的 ASCII 码，0x00 = 无字")
    w(");")
    w("")
    w("    always @(*) begin")
    w("        char_code = 7'h00;         // 默认无字（空格不单独占一项）")
    w("        case ({line_sel, col})")
    for li, text in enumerate(lines):
        if not text.strip():
            continue
        label = text.strip() if li != TICKER_LINE else "TICKER (64 cols)"
        w("            // ---- line %d: %s" % (li, label))
        for ci, ch in enumerate(text):
            if ch == " ":
                continue
            key = (li << 6) | ci
            w("            10'd%-4d: char_code = 7'h%02X;   // col %-2d '%s'"
              % (key, ord(ch), ci, ch))
    w("            default: char_code = 7'h00;")
    w("        endcase")
    w("    end")
    w("")
    w("endmodule")
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(a) + "\n")
    n_items = sum(1 for t in lines for ch in t if ch != " ")
    print("written: %s (%d lines, %d char entries)" % (out_path, len(a), n_items))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emit", action="store_true", help="写出 osd_strings.v")
    ap.add_argument("--show", action="store_true", help="打印列布局")
    args = ap.parse_args()
    lines = build_lines()
    check(lines)
    if args.show or not args.emit:
        show(lines)
    if args.emit:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        emit_verilog(os.path.join(root, "rtl", "osd", "osd_strings.v"), lines)


if __name__ == "__main__":
    main()
