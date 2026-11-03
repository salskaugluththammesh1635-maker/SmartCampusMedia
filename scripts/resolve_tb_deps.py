# -*- coding: utf-8 -*-
"""从 tb 出发，递归解析 rtl/ 下的模块依赖，输出完整源文件清单。

为什么需要它：手工列源文件清单已经错了两次（vlog 全绿但 vsim 报 vsim-3033），
因为 **vlog 不做 elaborate，缺模块不会报错**，要到 vsim 加载才暴露。
这个脚本按 tb 里实际例化的模块名递归找定义，直到闭包不再增长。

用法：
    python scripts\\resolve_tb_deps.py sim\\testbench\\tb_image_player.v
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RTL_DIRS = ['rtl', r'sim\testbench']
# 已知在 rtl/ 之外但仍需编进来的
EXTRA = [r'ip\local\sdram\global_def.v']

# 已知解析不到的模块（IP / 加密件 / 仿真行为模型），必须显式登记。
# 为什么必须显式：闭包少一个模块时的症状与「IP 模块没被解析进去」一模一样 ——
# vlog 全绿、vsim 报 vsim-3033 The design unit was not found。
# 不登记白名单就无法区分「这是正常的加密件」与「我漏了一个 rtl 文件」。
KNOWN_UNRESOLVED = {
    'sdr_as_ram': 'ip\\local\\sdram\\sdr_as_ram.enc.v（加密件，源码不在 rtl/ 下）',
    'IS42s32200': 'sdram 行为模型，仅仿真用，由 sdr_as_ram 内部或 tb 直接例化',
}

SKIP_WORDS = {
    'if', 'for', 'while', 'case', 'casex', 'casez', 'assign', 'always', 'initial',
    'begin', 'end', 'wire', 'reg', 'integer', 'genvar', 'generate', 'endgenerate',
    'module', 'endmodule', 'input', 'output', 'inout', 'parameter', 'localparam',
    'function', 'endfunction', 'task', 'endtask', 'else', 'repeat', 'forever',
    'posedge', 'negedge', 'or', 'and', 'not', 'real', 'time', 'defparam', 'return',
    # 第二版补：原表漏了这些，导致 endcase/while/repeat/chk 之类被当模块名
    'endcase', 'endfunction', 'endtask', 'endgenerate', 'endspecify',
    'while', 'repeat', 'fork', 'join', 'join_any', 'join_none',
    'wait', 'disable', 'force', 'release', 'specify', 'endspecify',
    'tri', 'tri0', 'tri1', 'wand', 'wor', 'signed', 'unsigned', 'supply0', 'supply1',
    'genvar', 'automatic', 'static', 'const', 'typedef', 'struct', 'enum',
    'always_ff', 'always_comb', 'always_latch', 'logic', 'bit', 'byte', 'int',
}


def strip_comments(text):
    text = re.sub(r'/\*.*?\*/', ' ', text, flags=re.S)
    text = re.sub(r'//[^\n]*', ' ', text)
    return text


def read(p):
    return io.open(p, encoding='utf-8', errors='replace').read()


def build_module_index():
    """模块名 -> 文件路径"""
    idx = {}
    files = []
    for d in RTL_DIRS:
        base = os.path.join(ROOT, d)
        for dirpath, _, names in os.walk(base):
            for n in names:
                if n.endswith('.v'):
                    files.append(os.path.join(dirpath, n))
    for p in files:
        txt = strip_comments(read(p))
        for m in re.finditer(r'^\s*module\s+([A-Za-z_]\w*)', txt, re.M):
            idx.setdefault(m.group(1), p)
    return idx


def instantiations(path):
    """粗解析一个文件里例化了哪些模块（够用即可，宁可多不可漏）"""
    txt = strip_comments(read(path))
    found = set()
    # 形式 1： mod #(...) u_x (     形式 2： mod u_x (
    for m in re.finditer(
            r'^[ \t]*([A-Za-z_]\w*)\b[ \t]*(?:#[ \t]*\([^;]*?\)[ \t]*)?([A-Za-z_]\w*)\b[ \t]*\(',
            txt, re.M):
        mod, inst = m.group(1), m.group(2)
        # mod 与 inst 都要过滤关键字：只滤 mod 的话，
        # 「endcase / if (...)」这种跨行拼接会以 inst='if' 混进来（if 恰好匹配 ^[a-z]+\d*$）
        if mod in SKIP_WORDS or inst in SKIP_WORDS:
            continue
        if not (inst.startswith('u_') or inst.startswith('dut') or
                inst.startswith('U_') or re.match(r'^[a-z]+\d*$', inst)):
            continue
        found.add(mod)
    return found


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    top = os.path.join(ROOT, sys.argv[1])
    if not os.path.exists(top):
        print('!! 找不到 %s' % top)
        return 2

    idx = build_module_index()
    print('索引到 %d 个模块' % len(idx))

    need = {top}
    seen = set()
    unresolved = set()
    changed = True
    while changed:
        changed = False
        for p in list(need):
            if p in seen:
                continue
            seen.add(p)
            for mod in instantiations(p):
                if mod in idx:
                    q = idx[mod]
                    if q not in need:
                        need.add(q)
                        changed = True
                else:
                    unresolved.add(mod)

    rel = []
    for p in sorted(need):
        rel.append(os.path.relpath(p, ROOT).replace('/', '\\'))
    for e in EXTRA:
        full = os.path.join(ROOT, e)
        if os.path.exists(full) and e not in rel:
            rel.append(e)

    print()
    print('=== 闭包 %d 个文件 ===' % len(rel))
    for r in rel:
        print('  ' + r)
    unexpected = sorted(unresolved - set(KNOWN_UNRESOLVED))
    expected = sorted(unresolved & set(KNOWN_UNRESOLVED))
    print()
    print('=== 未解析：预期 %d / 意外 %d ===' % (len(expected), len(unexpected)))
    for u in expected:
        print('  [预期] %-16s %s' % (u, KNOWN_UNRESOLVED[u]))
    for u in unexpected:
        print('  [意外] %-16s ← 不在 KNOWN_UNRESOLVED 里，可能是漏了 rtl 文件或解析器漏抓' % u)
    if unexpected:
        print()
        print('RESULT: FAIL  有 %d 个意外未解析模块（闭包可能不完整）' % len(unexpected))
        return 1
    print('RESULT: PASS  闭包 %d 个文件，未解析全部在预期白名单内' % len(rel))
    return 0


if __name__ == '__main__':
    sys.exit(main())
