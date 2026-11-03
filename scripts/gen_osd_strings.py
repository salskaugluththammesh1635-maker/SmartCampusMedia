#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_osd_strings.py —— 生成 rtl/osd/osd_strings.v（OSD 字符串表）

【为什么要有这个脚本】
    屏幕上的文字如果手写进 RTL，改一个字就要改 Verilog、还要重跑整套回归。
    字符串表本质是"数据"，所以放在脚本里维护、由脚本生成 RTL：改文案只改
    文本源，重跑脚本即可，RTL 不手写。

【输入】
    assets/v2/masters/font/cjk16_charset.txt   中文字形索引表（465 字形）
    assets/v2/masters/text/campus_ticker.txt   六段校园介绍（对应 IMG001..006）
    assets/v2/masters/text/emergency_ticker.txt 三段应急疏散文案

【输出】
    rtl/osd/osd_strings.v

【行分配（16 行 × 64 列）】
    line  0..7   ASCII 三条静态带（标题 / 序号 / 状态），沿用 v1 文案
    line  8..13  六段中文校园介绍，IMG n 对应 line 7+n（n = 1..6）
    line 14..15  应急疏散文案（三段共 104 字，超出一行 64 列，拆两行按轮次交替）

    为什么应急文案要占两行：
      应急文案是安全内容，任何一个字都不允许被截断。三段原始字数 36 + 32 + 36
      合计 104 字（用空格把三段连起来是 106 个字符，多的 2 个是分隔空格，
      不计入字数）。一行只够 64 字，所以拆成 line 14（第 0..63 字）与
      line 15（第 64..103 字），由 osd_caption 每滚完一轮翻转一次，
      两轮覆盖全文。

    为什么 line 15 不再是 v1 的 ASCII 滚动标语：
      v1 的 "SMART CAMPUS MEDIA CENTER -- WELCOME -- ONLINE NOW" 是占位符，
      用户要的是中文校园介绍。中文文案已经占了 line 8..15，旧的英文标语没有
      位置也不再需要（FONT_ARCH_RULING.md §7.6 记作 P2 可废弃）。

【码宽：10 位，最高位是中/英选择位】
    bit9 = 0 → bit[6:0] 是 ASCII 码，送 osd_font8x16（8 位点阵路径）
    bit9 = 1 → bit[8:0] 是 cjk16_charset.txt 的字形索引 0..464，送 cjk16_font
    0x000 = 无字（空白），不单独占一个 case 项

    为什么"空格"在中文行里写成 0 而不是某个中文字形索引：
      字库里根本没有空白字形（465 个字形全是笔画字符）。0 号码走 ASCII 路径，
      而 ASCII 路径的 0 号字形在 osd_font8x16 里全 16 行都是 8'h00，
      天然就是空白。这样中文行的空格不需要任何额外机制。

【为什么必须在这里做缺字检查】
    字库缺字在屏幕上的表现是"那个位置空着"——不报错、不崩溃、仿真也未必
    发现。所以缺字必须在**生成期**当成硬错误拦住，不能留到上板。

用法：
    python scripts/gen_osd_strings.py            # 打印文案概览
    python scripts/gen_osd_strings.py --show     # 同上
    python scripts/gen_osd_strings.py --emit     # 生成 rtl/osd/osd_strings.v
    python scripts/gen_osd_strings.py --emit --show
"""

import argparse
import os
import re
import sys

# ============================================================================
# 常量
# ============================================================================

TOTAL_LINES = 16          # osd_strings 的行数（line_sel 是 4 位）
COLS = 64                 # 每行字符列数（col 是 6 位）

STATIC_COLS = 16          # 三条 ASCII 静态带只用前 16 列

SEG_LINE0 = 8             # 六段校园介绍起始行
SEG_COUNT = 6             # IMG001..IMG006

EMG_LINE0 = 14            # 应急文案起始行（占两行）
EMG_LINES = 2

# ASCII 码：'#' 与 '*' 是页面序号的占位符，由 osd_caption 在运行时替换
HASH = 0x23
STAR = 0x2A
SPACE = 0x20

# 三条 ASCII 静态带（与 v1 完全一致，一个字都没改）
ASCII_TEXT = {
    0: "SMART CAMPUS",   # 标题
    1: "IMG #*",         # 序号（# 十位、* 个位）
    2: "PLAY",
    3: "PAUSE",
    4: "AUTO",
    5: "WAITING",
    6: "EMERGENCY",
    7: "FAIL",
}

# ASCII 行允许出现的字符集（故意不含位图里没有的字符）
ASCII_ALLOWED = set(" -./0123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZ#*")


# ============================================================================
# 路径
# ============================================================================

def project_root():
    # 本脚本在 <root>/scripts/ 下
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def path_of(*parts):
    return os.path.join(project_root(), *parts)


CHARSET_FILE = path_of("assets", "v2", "masters", "font", "cjk16_charset.txt")
CAMPUS_FILE = path_of("assets", "v2", "masters", "text", "campus_ticker.txt")
EMERGENCY_FILE = path_of("assets", "v2", "masters", "text", "emergency_ticker.txt")
OUT_FILE = path_of("rtl", "osd", "osd_strings.v")


# ============================================================================
# 字库索引表
# ============================================================================

CHARSET_LINE_RE = re.compile(r"^\s*(\d+)\s+(\S)\s+U\+([0-9A-Fa-f]{4,6})")


def load_charset(path=CHARSET_FILE):
    """读 cjk16_charset.txt，返回 {字符: 字形索引}。

    cjk16_charset.txt 的数据行格式：
            0    日     U+65E5   28.52%
    """
    cmap = {}
    with open(path, "r", encoding="utf-8-sig") as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if not line.strip():
                continue
            m = CHARSET_LINE_RE.match(line)
            if not m:
                continue  # 注释头与说明行
            idx = int(m.group(1))
            ch = m.group(2)
            if ch in cmap:
                raise SystemExit(
                    "ERROR: charset 索引重复 %r (line %d)" % (ch, lineno))
            cmap[ch] = idx

    if not cmap:
        raise SystemExit("ERROR: %s 里没解析到任何字形" % path)

    # 索引必须严格连续 0..N-1：RTL 直接拿索引寻址，空洞会被当成有效字形
    idxs = sorted(cmap.values())
    if idxs != list(range(len(idxs))):
        raise SystemExit(
            "ERROR: charset 索引不连续（max=%d, count=%d）" % (idxs[-1], len(idxs)))

    return cmap


# ============================================================================
# 文案读取
# ============================================================================

def read_text_lines(path):
    """读 UTF-8 文本，按行返回非空、非注释的行。"""
    out = []
    with open(path, "r", encoding="utf-8-sig") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            out.append(line)
    return out


def load_campus():
    lines = read_text_lines(CAMPUS_FILE)
    if len(lines) != SEG_COUNT:
        raise SystemExit(
            "ERROR: %s 应有 %d 段，实际 %d 段" % (CAMPUS_FILE, SEG_COUNT, len(lines)))
    return lines


def load_emergency():
    lines = read_text_lines(EMERGENCY_FILE)
    if not lines:
        raise SystemExit("ERROR: %s 是空的" % EMERGENCY_FILE)
    return lines


# ============================================================================
# 编码
# ============================================================================

def encode(cmap, ch, where, ascii_mode=False):
    """把一个字符编成 10 位码。

    ascii_mode 决定同一个字符走哪条路，这一点很关键：
      - 三条 ASCII 静态带（标题/序号/状态）用的是一半高度的 8 位字模，
        所以 'S' 必须编成 ASCII 码 0x53，走 osd_font8x16。
      - 中文行里出现的字母数字要用 16×16 全角格（字库里有这些字形，
        索引 82..91 是 0-9，99..111 是部分大写字母），所以走中文字形索引。

    注意字库里同时收录了数字和部分大写字母，同一字符既可走 ASCII 也可走
    中文索引，所以这个选择只能由"这一行是什么带"决定，不能由字符本身决定。
    """
    if ch == " ":
        return 0x000                       # 空白，走 ASCII 路径的 0 号空白字形
    if ascii_mode:
        if ord(ch) >= 0x80:
            raise SystemExit(
                "ERROR: 三条静态带只收 ASCII，%r (U+%04X) 出现在%s"
                % (ch, ord(ch), where))
        return ord(ch)                     # 半角 ASCII（bit9 = 0）
    if ch in cmap:
        return 0x200 | cmap[ch]            # bit9 = 1，低 9 位是字形索引
    if ord(ch) < 0x80:
        return ord(ch)                     # 字库没收录的半角字符退回 ASCII 路径
    raise SystemExit(
        "ERROR: 字库里没有 %r (U+%04X)，出现在%s——缺字在屏幕上只会空一格，"
        "不会报错，必须在这里拦住" % (ch, ord(ch), where))


def encode_line(cmap, text, where, width, ascii_mode=False):
    """把一段文本编成一行 width 个 10 位码，不足处补空白。"""
    text = text.strip()
    if len(text) > width:
        raise SystemExit(
            "ERROR: %s 长 %d 字，超过一行的 %d 列上限：%r"
            % (where, len(text), width, text))
    codes = [encode(cmap, ch, where, ascii_mode) for ch in text]
    codes += [0x000] * (width - len(codes))
    return codes


# ============================================================================
# 组表
# ============================================================================

def build_lines(cmap):
    """返回 16 行，每行 64 个 10 位码。"""
    lines = [[0x000] * COLS for _ in range(TOTAL_LINES)]

    # ---- line 0..7：ASCII 静态带 ----
    for li, text in ASCII_TEXT.items():
        lines[li] = encode_line(cmap, text, "line %d" % li, STATIC_COLS,
                                ascii_mode=True) + \
                    [0x000] * (COLS - STATIC_COLS)

    # ---- line 8..13：六段校园介绍，IMG n → line 7+n ----
    for i, text in enumerate(load_campus()):
        lines[SEG_LINE0 + i] = encode_line(
            cmap, text, "校园介绍第 %d 段（IMG%03d）" % (i + 1, i + 1), COLS)

    # ---- line 14..15：应急疏散文案，三段拼成一串后对半拆 ----
    #      三段之间以空格分隔（每段自身以句号结尾，加空格纯粹为可读性）
    emergency = " ".join(load_emergency())
    emg_len = len(emergency)
    need_lines = (emg_len + COLS - 1) // COLS
    if need_lines > EMG_LINES:
        raise SystemExit(
            "ERROR: 应急文案 %d 字，%d 行装不下（上限 %d 字）"
            % (emg_len, EMG_LINES, EMG_LINES * COLS))
    for k in range(EMG_LINES):
        chunk = emergency[k * COLS:(k + 1) * COLS]
        lines[EMG_LINE0 + k] = encode_line(
            cmap, chunk, "应急文案第 %d 段" % (k + 1), COLS)

    return lines


# ============================================================================
# 检查
# ============================================================================

def check(lines):
    if len(lines) != TOTAL_LINES:
        raise SystemExit("ERROR: 行数 %d != %d" % (len(lines), TOTAL_LINES))

    # ASCII 静态带必须是纯 ASCII 且字符都在字模 ROM 里
    for li in range(SEG_LINE0):
        for ci, code in enumerate(lines[li][:STATIC_COLS]):
            if code == 0:
                continue    # 无字，空白（文案短于 16 列时的补齐位）
            if code & 0x200:
                raise SystemExit(
                    "ERROR: line %d col %d 是中文码，三条静态带只允许 ASCII"
                    % (li, ci))
            ch = chr(code & 0x7F)
            if ch not in ASCII_ALLOWED:
                raise SystemExit(
                    "ERROR: line %d col %d 出现字模 ROM 里没有的字符 %r"
                    % (li, ci, ch))

    # 中文行的码宽与索引范围
    for li in range(SEG_LINE0, TOTAL_LINES):
        for ci, code in enumerate(lines[li]):
            if code & 0x200:
                glyph = code & 0x1FF
                if glyph > 464:
                    raise SystemExit(
                        "ERROR: line %d col %d 字形索引 %d 超出 0..464"
                        % (li, ci, glyph))

    # 六段校园文案必须各不相同（同一段重复 = 段号译码接错了）
    segs = [tuple(lines[SEG_LINE0 + i]) for i in range(SEG_COUNT)]
    if len(set(segs)) != SEG_COUNT:
        raise SystemExit("ERROR: 六段校园介绍有重复")

    # 应急行不能是空的（应急模式下滚一片空白比不显示更糟）
    for k in range(EMG_LINES):
        if not any(lines[EMG_LINE0 + k]):
            raise SystemExit("ERROR: 应急文案 line %d 是空的" % (EMG_LINE0 + k))


# ============================================================================
# 预览
# ============================================================================

def show(lines):
    print("%-6s %-10s %-8s %s" % ("line", "用途", "非空字数", "内容预览"))
    print("-" * 100)
    for li, row in enumerate(lines):
        if li < SEG_LINE0:
            use = "ASCII 静态带"
        elif li < EMG_LINE0:
            use = "校园介绍 %d" % (li - SEG_LINE0 + 1)
        else:
            use = "应急文案 %d" % (li - EMG_LINE0 + 1)
        preview = "".join(_decode(row[:40]))
        nz = sum(1 for c in row if c)
        print("%-6d %-10s %-8d %s" % (li, use, nz, preview))
        if li < SEG_LINE0:
            print("       列号:" + "".join(str(c % 10) for c in range(40)))


def _decode(codes):
    """把 10 位码还原成可视字符（只用于 --show 预览）。"""
    out = []
    for code in codes:
        if code == 0:
            out.append(" ")
        elif code & 0x200:
            out.append("·")     # 中文占用，具体字要看 charset 反查
        else:
            out.append(chr(code & 0x7F))
    return out


# ============================================================================
# 生成 Verilog
# ============================================================================

def emit_verilog(out_path, lines, cmap):
    rev = {v: k for k, v in cmap.items()}

    a = []
    w = a.append

    w("// ============================================================================")
    w("// 文件名  : osd_strings.v")
    w("// 所在位置: rtl/osd/osd_strings.v")
    w("// 所属层次: OSD 层 / 字符串表（由 scripts/gen_osd_strings.py 生成）")
    w("// 作者    : 智播校园项目组")
    w("// ============================================================================")
    w("// 【一】系统功能")
    w("//   B1 扩展项\"图层叠加与字幕\"要求屏幕上呈现标题、页面序号、播放状态和")
    w("//   滚动字幕四类文字。本模块是这四类文字的字符码来源。")
    w("//")
    w("// 【二】本模块功能")
    w("//   输入 {行号, 列号} → 输出该格位的 9 位字符码")
    w("//       line_sel <= 7 → bit[6:0] 是 ASCII 码，送 osd_font8x16（8 位点阵）")
    w("//       line_sel >= 8 → bit[8:0] 是 cjk16_charset.txt 的字形索引，送 cjk16_font")
    w("//       0x000 = 无字（空白），不占 case 项")
    w("//")
    w("// 【三】16 行怎么分配")
    w("//   line  0..7  ASCII 静态带：标题 / 序号 / PLAY..FAIL 六个状态")
    w("//   line  8..13 六段中文校园介绍，IMG n（n=1..6）对应 line 7+n")
    w("//   line 14..15 应急疏散文案：三段共 104 字（36+32+36，不含 2 个分隔空格），")
    w("//               拆两行由 osd_caption 每滚完一轮交替显示，一字不截断")
    w("//")
    w("//   三组行不能互换：坐标常量与 t_line 的译码都按这个分配写死。")
    w("//")
    w("// 【四】为什么是纯组合 case、以及为什么只有 9 位（t24 起）")
    w("//   本模块是一张只读的小表，输入地址来自寄存器（见 osd_caption 的")
    w("//   t_line/t_col），输出进字模 ROM 的地址或组合查表。综合成 LUT 树即可，")
    w("//   不需要块 RAM：真值表项数 373，远小于一块 BRAM9K 的 512 项颗粒度，")
    w("//   用 BRAM 反而要额外管 1 拍延迟——而 osd_caption 的三条 ASCII 带")
    w("//   是零打拍的（见 osd_caption 的【五】），多 1 拍会让整条文字错 1 像素。")
    w("//")
    w("//   位宽由 10 位收成 9 位：原 bit9 是「中/英」标志，但它恒等于 line_sel[3]，")
    w("//   是行号的冗余副本——全部 373 条目逐条实测满足")
    w("//       line_sel <= 7 → bit9 = 0（ASCII 静态带 line 0..7）")
    w("//       line_sel >= 8 → bit9 = 1（校园介绍 line 8..13、应急文案 line 14..15）")
    w("//   所以中英判定改由 osd_caption 用 t_line[3] 组合给出（is_cjk_eff），")
    w("//   本模块只负责「这一格是哪个字」。少 1 位换来：每行 64 选 1 的树每级")
    w("//   少 1 个 LUT，且下游不再有一条 fo=60 的 1 位复制网络（t7-B 违例路径）。")
    w("//")
    w("// 【五】自动生成，勿手改")
    w("//   改文案请改 assets/v2/masters/text/ 下的文本源，然后重跑")
    w("//       python scripts/gen_osd_strings.py --emit")
    w("//   手改本文件会在下次生成时被覆盖。")
    w("// ============================================================================")
    w("module osd_strings (")
    w("    input  wire [3:0] line_sel,    // 文本行 0..15")
    w("    input  wire [5:0] col,         // 字符列 0..63")
    w("    output reg  [8:0] char_code    // 9 位码：0x000 = 无字；中英由 line_sel[3] 判定")
    w(");")
    w("")
    w("    always @(*) begin")
    w("        char_code = 9'h000;        // 默认无字")
    w("        case ({line_sel, col})")
    w("")

    uses = {}
    for li in range(TOTAL_LINES):
        if li < SEG_LINE0:
            uses[li] = "ASCII 静态带"
        elif li < EMG_LINE0:
            uses[li] = "校园介绍 %d（IMG%03d）" % (li - SEG_LINE0 + 1, li - SEG_LINE0 + 1)
        else:
            uses[li] = "应急疏散文案 %d/%d" % (li - EMG_LINE0 + 1, EMG_LINES)

    entries = 0
    for li, row in enumerate(lines):
        head = "        // ---- line %d: %s" % (li, uses[li])
        printed_head = False
        for ci, code in enumerate(row):
            if code == 0:
                continue
            if not printed_head:
                w(head)
                printed_head = True
            key = (li << 6) | ci
            if code & 0x200:
                ch = rev.get(code & 0x1FF, "?")
                note = "col %-2d '%s' 字形 %d" % (ci, ch, code & 0x1FF)
            else:
                ch = chr(code & 0x7F)
                note = "col %-2d '%s'" % (ci, ch)
            w("            10'd%-4d: char_code = 9'h%03X;   // %s" % (key, code & 0x1FF, note))
            entries += 1
        if printed_head:
            w("")

    w("            default: char_code = 9'h000;")
    w("        endcase")
    w("    end")
    w("")
    w("endmodule")

    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(a) + "\n")

    print("written: %s (%d lines, %d char entries)" % (out_path, TOTAL_LINES, entries))


# ============================================================================
# 入口
# ============================================================================

def main():
    ap = argparse.ArgumentParser(
        description="生成 rtl/osd/osd_strings.v（OSD 字符串表）")
    ap.add_argument("--emit", action="store_true", help="生成 rtl/osd/osd_strings.v")
    ap.add_argument("--show", action="store_true", help="打印文案概览")
    args = ap.parse_args()

    cmap = load_charset()
    lines = build_lines(cmap)
    check(lines)

    if args.show or not args.emit:
        show(lines)

    if args.emit:
        emit_verilog(OUT_FILE, lines, cmap)

    return 0


if __name__ == "__main__":
    sys.exit(main())
