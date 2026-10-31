#!/usr/bin/env python3
"""从 RTL 提取字模与字符表，生成数据手册用的 TikZ 资产。

【为什么从 RTL 提取而不是手画】
  手册里的字符集表和字符串表映射图，如果是人手画的示意图，就会和代码
  脱钩 —— 改了字模、改了文案，手册还是旧的，读者按手册去改代码必然出错。
  本脚本直接解析 rtl/osd/*.v，把 ROM 里的真实常量画成图，手册因此
  永远与代码同步：重跑一次即可。

用法:
  python scripts/gen_datasheet_assets.py
输出:
  docs/datasheet/assets/font_glyphs.tex   41 个字形的点阵图宏
  docs/datasheet/assets/strings_map.tex   16x64 地址映射图
  docs/datasheet/assets/strings_list.tex  各行内容清单（表格行）
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FONT_V = ROOT / "rtl" / "osd" / "osd_font8x16.v"
STR_V = ROOT / "rtl" / "osd" / "osd_strings.v"
OUT = ROOT / "docs" / "datasheet" / "assets"

# 栅格化参数，与 scripts/gen_osd_font8.py 保持一致（对比图要能复现当初的实测）
FONT_PATH = r"C:\Windows\Fonts\consolab.ttf"
THRESHOLD = 100

# 与 gen_osd_font8.py 的 CHARSET 一致；顺序决定手册里字形的排列顺序
CHARSET = " -./0123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZ"


def parse_font(path: Path) -> dict[int, list[int]]:
    """{rom_index: [16 行的 8 位点阵]}"""
    text = path.read_text(encoding="utf-8", errors="replace")
    out: dict[int, list[int]] = {}
    for m in re.finditer(r"10'd(\d+)\s*:\s*pixels\s*=\s*8'h([0-9A-Fa-f]{2})\s*;", text):
        idx, val = int(m.group(1)), int(m.group(2), 16)
        code, row = idx >> 4, idx & 0xF
        out.setdefault(code, [0] * 16)[row] = val
    return out


def parse_strings(path: Path) -> dict[int, dict[int, int]]:
    """{line: {col: ascii}}"""
    text = path.read_text(encoding="utf-8", errors="replace")
    out: dict[int, dict[int, int]] = {}
    for m in re.finditer(r"10'd(\d+)\s*:\s*char_code\s*=\s*7'h([0-9A-Fa-f]{2})\s*;", text):
        idx, code = int(m.group(1)), int(m.group(2), 16)
        line, col = idx >> 6, idx & 0x3F
        out.setdefault(line, {})[col] = code
    return out


def runs(bits: int, width: int = 8) -> list[tuple[int, int]]:
    """把一行点阵拆成若干连续 1 的区段 [(起始列, 长度)]，减少 TikZ 图元数

    bit(width-1) 是最左像素，与 RTL 的 8 位字模约定一致。
    """
    segs = []
    col = 0
    while col < width:
        if bits & (1 << (width - 1 - col)):
            start = col
            while col < width and (bits & (1 << (width - 1 - col))):
                col += 1
            segs.append((start, col - start))
        else:
            col += 1
    return segs


def esc_tex(ch: str) -> str:
    """转义 TeX 特殊字符（本字符集里 '/' '.' ':' '-' 都安全，'#' 需转义）"""
    return {"#": r"\#", "$": r"\$", "%": r"\%", "&": r"\&", "_": r"\_",
            "{": r"\{", "}": r"\}", "~": r"\textasciitilde{}",
            "^": r"\textasciicircum{}", "\\": r"\textbackslash{}"}.get(ch, ch)


def esc_text(s: str) -> str:
    """把任意字符串转义成可安全放进 TeX 正文的形式

    RTL 注释里出现 '#' '_' '&' 之类是常态（如"供 # / * 替换"、"active_x"），
    直接抄进 .tex 会让整篇编译失败。这里逐字符转义，并把换行压成空格。
    """
    out = []
    for ch in s:
        if ch in "#$%&_{}":
            out.append("\\" + ch)
        elif ch == "~":
            out.append(r"\textasciitilde{}")
        elif ch == "^":
            out.append(r"\textasciicircum{}")
        elif ch == "\\":
            out.append(r"\textbackslash{}")
        else:
            out.append(ch)
    return "".join(out)


def emit_font(font: dict[int, list[int]], path: Path) -> int:
    """生成 41 个字形宏 \\dsg@N 与单参数绘图宏 \\dsglyph{N}

    【为什么用 \\csname 而不是 \\ifnum 链】
      \\ifnum 链每画一个字形要扫过 41 个分支，画 41 个字形 = 1681 次比较；
      用 \\csname 定义 41 个独立宏后，调用变成 TeX 的哈希查找，O(1)。
    """
    lines = [
        "% ============================================================",
        "% 本文件由 scripts/gen_datasheet_assets.py 自动生成，请勿手改。",
        "% 内容来源: rtl/osd/osd_font8x16.v（逐项解析 case 常量）",
        "% ============================================================",
        "",
        r"\makeatletter",
        "",
        "% ---- 41 个字形宏：每个是一串 TikZ \\fill 图元（单位: 点阵格）----",
    ]
    total_fills = 0
    for i, ch in enumerate(CHARSET, start=1):
        rom = ord(ch) & 0x3F
        rows = font.get(rom, [0] * 16)
        lines.append(rf"\expandafter\def\csname dsg@{i}\endcsname{{%")
        for row in range(16):
            for start, length in runs(rows[row]):
                # TikZ 的 y 轴向上，行号 0 在最上 → y = 15-row
                lines.append(
                    rf"  \fill[dsink] ({start},{15 - row}) rectangle ++({length},1);%")
                total_fills += 1
        lines.append("}")
    lines += [
        "",
        "% ---- 调用接口 ----",
        "% \\dsglyph{rom_index} 画一个 8x16 点阵字形（不含标签）",
        "% 用 \\csname 做 O(1) 查找；若用 \\ifnum 链，画 41 个字形要扫 1681 个分支。",
        r"\newcommand{\dsglyph}[1]{%",
        r"  \begin{tikzpicture}[x=0.108cm,y=0.108cm,baseline={(0,0)}]%",
        r"    \fill[dsgrid] (0,0) rectangle (8,16);%",
        r"    \csname dsg@#1\endcsname",
        r"  \end{tikzpicture}%",
        r"}",
        "",
        r"\makeatother",
        "",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return total_fills


def emit_glyph_grid(font: dict[int, list[int]], path: Path) -> None:
    """生成字符集总表：每行 8 个字形，上方标字符、下方标 rom_index"""
    cols = 8
    rows = (len(CHARSET) + cols - 1) // cols
    lines = [
        "% 字符集总表 —— 由 gen_datasheet_assets.py 生成",
        r"{\setlength{\tabcolsep}{4pt}",
        r"\begin{tabular}{*{8}{c}}",
        r"\toprule",
    ]
    for r in range(rows):
        heads = []
        for c in range(cols):
            i = r * cols + c
            if i < len(CHARSET):
                ch = CHARSET[i]
                heads.append(r"\textvisiblespace" if ch == " "
                             else r"\texttt{" + esc_tex(ch) + "}")
            else:
                heads.append("")
        lines.append(" & ".join(heads) + r" \\[1pt]")
        glyphs = []
        for c in range(cols):
            i = r * cols + c
            glyphs.append(rf"\dsglyph{{{i + 1}}}" if i < len(CHARSET) else "")
        lines.append(" & ".join(glyphs) + r" \\[1pt]")
        codes = []
        for c in range(cols):
            i = r * cols + c
            codes.append(r"{\tiny\ttfamily " + str(ord(CHARSET[i]) & 0x3F) + "}"
                         if i < len(CHARSET) else "")
        lines.append(" & ".join(codes) + r" \\[5pt]")
    lines += [r"\bottomrule", r"\end{tabular}}"]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def emit_strings_map(strings: dict[int, dict[int, int]], path: Path) -> None:
    """生成 16x64 地址映射图：有字符的格子填色"""
    lines = [
        "% 字符串表地址映射 —— 由 gen_datasheet_assets.py 生成",
        r"\begin{tikzpicture}[x=0.105cm,y=0.105cm]",
        r"  % 每行 64 列；行号标注在左侧",
    ]
    for line in range(16):
        for col in range(64):
            if col in strings.get(line, {}):
                lines.append(
                    rf"  \fill[dsmap{min(line, 9) if line < 8 else 9}] ({col},{15 - line}) rectangle ++(0.92,0.92);")
    # 网格线
    lines.append(r"  \draw[dsmapline,step=1] (0,0) grid (64,16);")
    # 左侧行号
    for line in range(16):
        lines.append(rf"  \node[anchor=east,font=\scriptsize\ttfamily,inner sep=1pt] at (-0.3,{15 - line + 0.5}) {{{line}}};")
    # 底部列号刻度
    for col in (0, 8, 16, 24, 32, 40, 48, 56, 63):
        lines.append(rf"  \node[anchor=north,font=\scriptsize\ttfamily,inner sep=1pt] at ({col + 0.5},-0.3) {{{col}}};")
    lines += [r"\end{tikzpicture}"]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def emit_strings_list(strings: dict[int, dict[int, int]], path: Path) -> None:
    """生成各行内容清单的表格行

    空格在表里用 `·` 显式画出，否则读者无法判断"这里是真的没字，还是我数错了列"。
    长行（滚动标语 64 字符）折成多段，避免撑破表格。
    """
    lines = [
        "% 字符串表内容清单 —— 由 gen_datasheet_assets.py 生成，勿手改",
        r"\begin{tabular}{@{}c >{\raggedright\arraybackslash}p{8.2cm} c c@{}}",
        r"\toprule",
        r"\textbf{行} & \textbf{内容} & \textbf{字符数} & \textbf{列宽}\\",
        r"\midrule",
    ]
    for line in range(16):
        row = strings.get(line, {})
        if not row:
            continue
        width = max(row) + 1
        cells = []
        for c in range(width):
            if c in row:
                cells.append(esc_tex(chr(row[c])))
            else:
                cells.append(r"{\color{dsdim}\textperiodcentered}")
        # 每 16 列折一段，避免长行撑破表格
        chunks = ["".join(cells[i:i + 16]) for i in range(0, width, 16)]
        body = r" \allowbreak ".join(rf"\texttt{{{ch}}}" for ch in chunks)
        lines.append(
            rf"{line} & {body} & {len(row)} & {width} \\")
    lines += [r"\bottomrule", r"\end{tabular}"]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def rasterize(ch: str, cell_w: int, cell_h: int, size: int,
              base_y: int) -> list[int]:
    """用 PIL 现场把字符栅格化成点阵（bit7 = 最左像素）

    这里重新栅格化而不是复用 RTL 数据，是因为要画"8x8 长什么样"的对比图——
    RTL 里只有 8x16 的数据。用与 scripts/gen_osd_font8.py 完全相同的字体、
    字号、对齐方式，保证对比图说的就是当初实测的那件事。
    """
    from PIL import Image, ImageDraw, ImageFont
    img = Image.new("L", (cell_w, cell_h), 0)
    font = ImageFont.truetype(FONT_PATH, size)
    ImageDraw.Draw(img).text((cell_w // 2, base_y), ch, fill=255,
                             font=font, anchor="ms")
    rows = []
    for y in range(cell_h):
        bits = 0
        for x in range(cell_w):
            if img.getpixel((x, y)) >= THRESHOLD:
                bits |= 1 << (cell_w - 1 - x)
        rows.append(bits)
    return rows


def emit_glyph_compare(font: dict[int, list[int]], path: Path) -> None:
    """生成 8x8 vs 8x16 粒度对比图（完整 tikzpicture）

    【为什么由脚本画而不是手写 TikZ】
      初版在 .tex 里用 `\\pgfmathparse{int(substr(\\bits,\\c,1))}` 从一串
      二进制字符里取位——PGF 根本没有 substr 函数，直接编译报
      `Unknown function substr`。而且手写位串本身就是"凭记忆编数据"。
      改成 Python 现场栅格化，图上的每个像素都来自真实字体渲染。
    """
    small = {c: rasterize(c, 8, 8, 8, 6) for c in "AB8D0"}
    lines = [
        "% 8x8 vs 8x16 粒度对比 —— 由 gen_datasheet_assets.py 生成",
        r"\begin{tikzpicture}[x=0.155cm,y=0.155cm]",
    ]
    # 每个 8x8 点阵用若干 \fill 画出（连续 1 区段合并）
    for idx, ch in enumerate("AB8D0"):
        dx = idx * 11
        lines.append(rf"  % --- 8x8 栅格化的 {ch} ---")
        lines.append(rf"  \fill[dsgrid] ({dx},0) rectangle ++(8,8);")
        for row, bits in enumerate(small[ch]):
            for start, length in runs(bits, 8):
                lines.append(
                    rf"  \fill[dsink] ({dx + start},{7 - row}) rectangle ++({length},1);")
        lines.append(
            rf"  \node[below,font=\scriptsize\ttfamily] at ({dx + 4},-0.2) {{{ch}}};")
        # 同字符的 8x16 真实 ROM 数据放在下方
        rom = ord(ch) & 0x3F
        if rom in font:
            lines.append(rf"  \begin{{scope}}[shift={{({dx},-11)}}]")
            lines.append(rf"    \dsglyph{{{rom}}}")
            lines.append(r"  \end{scope}")
    lines += [
        r"\end{tikzpicture}",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def parse_ports(path: Path) -> list[dict]:
    """解析模块端口声明，供手册引脚表使用

    只处理工程里实际采用的两种写法：
      input  wire [10:0] active_x,      // 注释
      output wire        caption_pixel,
    以及 ANSI 头里跨多行的声明。解析失败不抛异常，返回空表 —— 手册里
    宁可少一张表，也不要因为脚本脆断而整篇编译不过。
    """
    if not path.exists():
        return []
    text = path.read_text(encoding="utf-8", errors="replace")
    ports = []
    pat = re.compile(
        r"^\s*(input|output|inout)\s+(?:wire|reg)?\s*"
        r"(?:\[(\d+):(\d+)\])?\s*([A-Za-z_]\w*)\s*(?:,|;)?\s*(?://\s*(.*))?$")
    for line in text.splitlines():
        m = pat.match(line)
        if not m:
            continue
        d, name, cmt = m.group(1), m.group(4), (m.group(5) or "").strip()
        if m.group(2):
            msb, lsb = int(m.group(2)), int(m.group(3))
            width = abs(msb - lsb) + 1
            rng = f"[{msb}:{lsb}]"
        else:
            width, rng = 1, ""
        ports.append({"dir": d, "name": name, "width": width,
                      "range": rng, "comment": cmt})
    return ports


def emit_ports(ports: list[dict], path: Path, colspec: str,
               headers: list[str]) -> None:
    """生成**完整**的 tabular 环境

    【为什么不用 tabularx】
      tabularx 需要多次扫描表格体来确定 X 列宽度，而 `\\input` 的文件流
      只能读一次 —— 第二次扫描读到的是文件末尾，于是 \\bottomrule 落在
      表格外面，报 `Misplaced \\noalign`。所以生成器直接输出完整的
      tabular 环境（含表头与规则线），手册里 \\input 整个表即可。
      代价是说明列宽要写死（p{...}），改版式得同时改 colspec。
    """
    dirmark = {"input": r"$\rightarrow$", "output": r"$\leftarrow$",
               "inout": r"$\leftrightarrow$"}
    lines = [
        "% 端口表 —— 由 gen_datasheet_assets.py 解析 RTL 生成，勿手改",
        rf"\begin{{tabular}}{{{colspec}}}",
        r"\toprule",
        " & ".join(rf"\textbf{{{h}}}" for h in headers) + r"\\",
        r"\midrule",
    ]
    for p in ports:
        rng = p["range"].replace("[", "{[}").replace("]", "{]}") if p["range"] else "--"
        if len(headers) == 5:            # 带"范围"列
            lines.append(
                rf"{dirmark[p['dir']]} & {{\ttfamily {esc_text(p['name'])}}} & "
                rf"{p['width']} & {{\scriptsize\ttfamily {rng}}} & "
                rf"{esc_text(p['comment'])} \\")
        else:                            # 紧凑 4 列：范围并进位宽
            wcell = rf"{p['width']}" + (rf"{{\scriptsize\ttfamily\ {rng}}}" if rng != "--" else "")
            lines.append(
                rf"{dirmark[p['dir']]} & {{\ttfamily {esc_text(p['name'])}}} & "
                rf"{wcell} & {esc_text(p['comment'])} \\")
    lines += [r"\bottomrule", r"\end{tabular}"]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    font = parse_font(FONT_V)
    strings = parse_strings(STR_V)

    print(f"字模: {len(font)} 个字形")
    print(f"字符表: {sum(len(v) for v in strings.values())} 项，"
          f"{len(strings)} 行有内容")

    n = emit_font(font, OUT / "font_glyphs.tex")
    print(f"written: font_glyphs.tex ({n} 个图元)")
    emit_glyph_grid(font, OUT / "glyph_grid.tex")
    print("written: glyph_grid.tex")
    emit_glyph_compare(font, OUT / "glyph_compare.tex")
    print("written: glyph_compare.tex")
    emit_strings_map(strings, OUT / "strings_map.tex")
    print("written: strings_map.tex")
    emit_strings_list(strings, OUT / "strings_list.tex")
    print("written: strings_list.tex")

    # 端口表列宽：方向/信号/位宽/范围 自然宽，说明列定宽（tabular 无 X 列）
    # 说明列宽度按各表实际可用宽度给：整幅表 7.2cm，并排双栏表 3.9cm
    hdr_full = ["", "信号", "位宽", "范围", "说明"]
    hdr_slim = ["", "信号", "宽", "说明"]
    port_jobs = (
        ("osd_caption", "ports_caption.tex", r"@{}c l c c p{7.2cm}@{}", hdr_full),
        ("osd_strings", "ports_strings.tex", r"@{}c l c p{3.9cm}@{}", hdr_slim),
        ("osd_font8x16", "ports_font.tex", r"@{}c l c p{3.9cm}@{}", hdr_slim),
    )
    for mod, fn, spec, hdr in port_jobs:
        ports = parse_ports(ROOT / "rtl" / "osd" / f"{mod}.v")
        emit_ports(ports, OUT / fn, spec, hdr)
        print(f"written: {fn} ({len(ports)} 端口)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
