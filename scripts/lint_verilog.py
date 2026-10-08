#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lint_verilog.py — 提交 TD 前的 Verilog 静态检查（针对安路 TD 报错规则）

检查项:
  E0 文件损坏: 分号后紧跟孤立标识符直到行尾（如 `...;S`）
     → 典型症状: TD 报 "syntax error near '4'" 等与实际位置错位的错误
       （已实际发生: seg_decoder.v 第 14 行末尾多出 'S'）
  E1 同一 always 块内, 同一变量既被阻塞(=)又被非阻塞(<=)赋值
     → 安路 TD 直接报 "mixed blocking and non-blocking assignments" ERROR
       （ModelSim 只警告, 容易漏过, 故单独检查）
  E2 同一变量在多个 always 块中被赋值（多驱动, 仿真出 X）

用法:
  python scripts/lint_verilog.py <目录或文件...>
  例: python scripts/lint_verilog.py rtl project/src

退出码: 0 = 无问题; 1 = 发现 E1/E2
"""
import re
import sys
from pathlib import Path

KEYWORDS = {
    'if', 'else', 'case', 'casex', 'casez', 'endcase', 'for', 'while', 'repeat',
    'begin', 'end', 'always', 'initial', 'assign', 'function', 'endfunction',
    'task', 'endtask', 'module', 'endmodule', 'posedge', 'negedge', 'or', 'and',
    'input', 'output', 'inout', 'wire', 'reg', 'integer', 'parameter', 'localparam',
    'default', 'return', 'generate', 'endgenerate', 'genvar', 'forever', 'wait',
}


def strip_comments(text: str) -> str:
    """去掉 // 行注释与 /* */ 块注释（保留字符串内容简化处理）"""
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'//[^\n]*', '', text)
    return text


def find_blocks(text: str):
    """定位 always 块体（begin...end 配对），返回 [(起始位置, 块文本, 行号)]"""
    blocks = []
    for m in re.finditer(r'\balways\b', text):
        i = m.end()
        # 找到 always 后面的 begin
        seg = text[i:i + 400]
        bm = re.search(r'\bbegin\b', seg)
        if not bm:
            # 单语句 always（无 begin）: 取到第一个分号
            sm = re.search(r';', seg)
            if sm:
                blocks.append((m.start(), seg[:sm.end()], text[:m.start()].count('\n') + 1))
            continue
        start = i + bm.end()
        depth = 1
        j = start
        while j < len(text) and depth > 0:
            tok = re.match(r'[A-Za-z_]\w*', text[j:])
            if tok:
                w = tok.group(0)
                if w == 'begin':
                    depth += 1
                elif w == 'end':
                    depth -= 1
                    if depth == 0:
                        break
                j += len(w)
            else:
                j += 1
        blocks.append((m.start(), text[start:j], text[:m.start()].count('\n') + 1))
    return blocks


def find_function_ranges(text: str):
    """定位 function/task 体范围（其内部阻塞赋值合法，需排除）"""
    ranges = []
    for m in re.finditer(r'\b(function|task)\b', text):
        kw = m.group(1)
        endkw = 'endfunction' if kw == 'function' else 'endtask'
        e = text.find(endkw, m.end())
        if e == -1:
            e = len(text)
        ranges.append((m.start(), e))
    return ranges


def in_ranges(pos: int, ranges) -> bool:
    return any(a <= pos < b for a, b in ranges)


ASSIGN_RE = re.compile(
    r'([A-Za-z_]\w*)'            # 变量名
    r'((?:\s*\[[^\]]*\])*)'      # 可选的位选/索引（含 +: 形式）
    r'\s*(<=|=)(?!=)'            # 赋值符（<= 非阻塞 / = 阻塞, 排除 ==）
)


def analyze(path: Path):
    raw = path.read_text(encoding='utf-8', errors='ignore')
    text = strip_comments(raw)
    fn_ranges = find_function_ranges(text)
    blocks = find_blocks(text)

    e1, e2, e0 = [], [], []
    driven = {}   # 变量 -> [(块序号, 行号)]

    # ---- E0: 文件损坏检测（分号后孤立"非关键字"标识符, 如 ...;S）----
    # 注意: "…; end" / "…; else" 等属合法的同行多语句结构, 必须排除关键字
    for i, ln in enumerate(raw.splitlines(), 1):
        code = ln.split('//')[0]
        m = re.search(r';[ \t]*([A-Za-z_]\w*)[ \t]*$', code)
        if m and m.group(1) not in KEYWORDS:
            e0.append((i, f'分号后多出孤立标识符 "{m.group(1)}"', ln.strip()[:80]))

    for bi, (bpos, body, bline) in enumerate(blocks):
        nb, blk = {}, {}
        for m in ASSIGN_RE.finditer(body):
            pos_in_text = bpos + m.start()
            if in_ranges(pos_in_text, fn_ranges):
                continue                      # function/task 内部, 跳过
            var, _, op = m.group(1), m.group(2), m.group(3)
            if var in KEYWORDS:
                continue
            # 跳过连续赋值/声明里的东西（简单启发: 前面紧跟 wire/reg/input/output）
            lineno = bline + body[:m.start()].count('\n')
            (nb if op == '<=' else blk)[var] = lineno
            driven.setdefault(var, []).append((bi, lineno))

        both = set(nb) & set(blk)
        for v in sorted(both):
            e1.append((v, blk[v], nb[v]))

    for v, hits in driven.items():
        blks = {b for b, _ in hits}
        if len(blks) > 1:
            e2.append((v, sorted({ln for _, ln in hits})))

    return e0, e1, e2, len(blocks)


def main(argv):
    targets = argv[1:] or ['rtl']
    files = []
    for t in targets:
        p = Path(t)
        if p.is_dir():
            files += sorted(p.rglob('*.v'))
        elif p.exists():
            files.append(p)

    total_e0 = total_e1 = total_e2 = 0
    for f in files:
        e0, e1, e2, nblk = analyze(f)
        if not e0 and not e1 and not e2:
            continue
        print(f'\n=== {f}  (always 块 {nblk} 个) ===')
        for ln, why, txt in e0:
            print(f'  [E0] 行{ln} 文件损坏: {why}\n         内容: {txt}')
            total_e0 += 1
        for v, bl, nl in e1:
            print(f'  [E1] 变量 "{v}" 在同一 always 块内混用阻塞/非阻塞'
                  f'  (阻塞@行{bl}, 非阻塞@行{nl})  → TD 会报 ERROR')
            total_e1 += 1
        for v, lns in e2:
            print(f'  [E2] 变量 "{v}" 被多个 always 块驱动 (行 {lns}) → 多驱动')
            total_e2 += 1

    print(f'\n检查文件数: {len(files)}')
    print(f'E0(文件损坏): {total_e0}    E1(赋值混用): {total_e1}    E2(多驱动): {total_e2}')
    if total_e0 or total_e1 or total_e2:
        print('结论: 存在问题, 请修复后再提交 TD')
        return 1
    print('结论: 通过（无损坏 / 无混用赋值 / 无多驱动）')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
