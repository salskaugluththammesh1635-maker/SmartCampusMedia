# -*- coding: utf-8 -*-
"""check_key9_shared.py — Key9 双消费者「同源」结构性判据

【为什么需要这个脚本（它补的是 check_port_names.py 抓不到的两类错）】
  check_port_names.py 只比对**端口名**存不存在、有没有接。下面两类错它一律 PASS：
    ① `.active_x(active_x)`  →  `.active_x(11'd0)`     名字对、位宽对、不是空括号
    ② `{5'd0, rm_win_w}`     →  `{2'd0, rm_win_w}`     补零位宽写错，端口仍接对
  而这两类错的后果都是**上板静默失效**：
    ① pix_reader 内部 map_key9_ident 恒真 → Key9 按下画面不变，但告警全部消失；
    ② win_w 高位被截断/错扩 → 窗口边界算错 → 画面被切一块，不报错。
  2026-11-02 实测：把 ① ② 分别注入顶层，check_port_names 均 RESULT: PASS / EXIT=0。

【本脚本查什么】
  不查端口名，查**结构**：Key9 的四根几何参数必须满足
      「单一驱动源（ratio_map）→ 单一中间 wire（k9_win_*）→ 两处消费者」
  中间任何一环断掉、被旁路、或多出一个来源，都判 FAIL。
  逐条断言见 ASSERTS 表（每条都能判真假，失败时打印实际值）。

【用法】
  python scripts\\check_key9_shared.py [top_file]
  退出码：0 = 全部断言通过；1 = 至少一条不通过（逐条列出）

【反证记录（2026-11-02，双计数）】
  A. `.win_w(k9_win_w)` → `.win_w()`        ：K6 命中（注入前 2 次 → 注入后 0 次）
  B. `.active_x(active_x)` → `.active_x(11'd0)`：K8 命中（注入前 8 次 → 注入后 0 次）
  C. `{5'd0, rm_win_w}` → `{2'd0, rm_win_w}` ：K4 命中（注入前 1 次 → 注入后 0 次）
  —— 三条都必须让本脚本 EXIT=1，否则本脚本本身就是「永远返回通过」的假判据。
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOP = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'rtl', 'top', 'dmz_eg4s20_hdmi_top.v')


def strip_comments(text):
    """去掉 // 行注释与 /* */ 块注释，但保留字符串内容（本文件里没有 Verilog 字符串端口）。"""
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'//[^\n]*', '', text)
    return text


def find_instance(code, module, inst):
    """返回 (module, inst) 对应的例化块文本（从 `module inst` 到配对的 `);`）。"""
    m = re.search(r'\b%s\s+%s\s*\(' % (re.escape(module), re.escape(inst)), code)
    if not m:
        return None
    i = m.end() - 1          # 指向 '('
    depth = 0
    j = i
    while j < len(code):
        c = code[j]
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return code[m.start():j + 1]
        j += 1
    return None


def conn(block, port):
    """取出例化块里 `.port(...)` 的实际连接表达式（去空白）；未连接返回 None，空括号返回 ''。"""
    m = re.search(r'\.\s*%s\s*\(' % re.escape(port), block)
    if not m:
        return None
    i = m.end() - 1
    depth = 0
    j = i
    while j < len(block):
        c = block[j]
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return block[i + 1:j].strip()
        j += 1
    return None


def count_all(code, pat):
    return len(re.findall(pat, code))


def main():
    raw = io.open(TOP, encoding='utf-8', newline='').read()
    code = strip_comments(raw)
    results = []   # (id, 说明, passed, detail)

    def check(cid, desc, passed, detail):
        results.append((cid, desc, bool(passed), detail))

    # ---------------------------------------------------------------- 抓例化块
    u_ratio = find_instance(code, 'ratio_map', 'u_ratio')
    u_mask = find_instance(code, 'image_window_mask', 'u_image_mask')
    u_player = find_instance(code, 'image_player', 'u_player')
    u_vtg = find_instance(code, 'video_timing_gen', 'u_vtg')

    check('K1', 'ratio_map 恰好例化 1 次（名字必须是 u_ratio）',
          u_ratio is not None and count_all(code, r'\bratio_map\s+\w+\s*\(') == 1,
          'u_ratio=%s, 全部 ratio_map 例化数=%d' % (
              'found' if u_ratio else 'MISSING', count_all(code, r'\bratio_map\s+\w+\s*\(')))

    if u_ratio is None or u_mask is None or u_player is None or u_vtg is None:
        for cid, desc, ok, det in [('K0', '三个例化块都能定位（否则后续断言无法进行）', False,
                                    'u_ratio=%s u_mask=%s u_player=%s u_vtg=%s' % (
                                        bool(u_ratio), bool(u_mask), bool(u_player), bool(u_vtg)))]:
            print('[%s] FAIL  %s\n       %s' % (cid, desc, det))
        return 1

    # ------------------------------------------------- K2 ratio_map 输出接 rm_*
    rm_expect = {'win_w': 'rm_win_w', 'win_h': 'rm_win_h',
                 'win_off_x': 'rm_win_off_x', 'win_off_y': 'rm_win_off_y'}
    bad = []
    for port, want in rm_expect.items():
        got = conn(u_ratio, port)
        if got != want:
            bad.append('%s: 期望 %s，实际 %r' % (port, want, got))
    check('K2', 'u_ratio 四个输出分别接 rm_win_w / rm_win_h / rm_win_off_x / rm_win_off_y',
          not bad, '; '.join(bad) if bad else 'OK')

    # ------------------------------------- K3 rm_* 各只有一条补零赋值（单一驱动源）
    pad = {'rm_win_w': 5, 'rm_win_h': 6, 'rm_win_off_x': 5, 'rm_win_off_y': 6}
    bad = []
    for sig, nbits in pad.items():
        # 形如：wire [15:0] k9_win_w = {5'd0, rm_win_w};
        pat = r"\bwire\s*\[\s*15\s*:\s*0\s*\]\s*k9_%s\s*=\s*\{\s*%d\s*'\s*d\s*0\s*,\s*%s\s*\}" % (
            sig.replace('rm_', ''), nbits, re.escape(sig))
        if count_all(code, pat) != 1:
            bad.append('%s 的补零赋值期望恰好 1 条，实际 %d 条（模式 %s）' % (
                sig, count_all(code, pat), pat))
    check('K3', '四根 rm_* 各自恰好被一条 {N\'d0, ...} 补零赋值消费（无第二驱动源）',
          not bad, '; '.join(bad) if bad else 'OK')

    # ------------------------------------------------- K4 补零位宽必须精确
    bad = []
    for sig, nbits in pad.items():
        k9 = 'k9_' + sig.replace('rm_', '')
        m = re.search(r"\bwire\s*\[\s*15\s*:\s*0\s*\]\s*%s\s*=\s*\{\s*(\d+)\s*'\s*d" % re.escape(k9), code)
        got = int(m.group(1)) if m else None
        if got != nbits:
            bad.append('%s 补零位数期望 %d，实际 %s（ratio_map 输出 %s）' % (
                k9, nbits, got, {'rm_win_w': '11 位', 'rm_win_h': '10 位',
                                 'rm_win_off_x': '11 位', 'rm_win_off_y': '10 位'}[sig]))
    check('K4', '补零位宽精确：rm_win_w/rm_win_off_x 补 5 位，rm_win_h/rm_win_off_y 补 6 位',
          not bad, '; '.join(bad) if bad else 'OK')

    # --------------------------------- K5 k9_win_* 各恰好一条 wire 声明（唯一中间层）
    bad = []
    for k9 in ['k9_win_w', 'k9_win_h', 'k9_win_off_x', 'k9_win_off_y']:
        n_decl = count_all(code, r'\bwire\s*\[\s*15\s*:\s*0\s*\]\s*%s\s*=' % re.escape(k9))
        if n_decl != 1:
            bad.append('%s 声明数期望 1，实际 %d' % (k9, n_decl))
    check('K5', '四根 k9_win_* 各自恰好一条 wire 声明（中间层唯一）',
          not bad, '; '.join(bad) if bad else 'OK')

    # ------------------------------------------- K6 / K7 两处消费者接同一组 k9_*
    win_ports = [('win_w', 'k9_win_w'), ('win_h', 'k9_win_h'),
                 ('win_off_x', 'k9_win_off_x'), ('win_off_y', 'k9_win_off_y')]
    bad = []
    for port, want in win_ports:
        got = conn(u_mask, port)
        if got != want:
            bad.append('image_window_mask.%s: 期望 %s，实际 %r' % (port, want, got))
    check('K6', 'image_window_mask 的四个 win_* 接 k9_win_*（位置门控侧）',
          not bad, '; '.join(bad) if bad else 'OK')

    bad = []
    for port, want in win_ports:
        got = conn(u_player, port)
        if got != want:
            bad.append('image_player.%s: 期望 %s，实际 %r' % (port, want, got))
    check('K7', 'image_player 的四个 win_* 接**同一组** k9_win_*（采样范围侧）',
          not bad, '; '.join(bad) if bad else 'OK')

    # --------------------------------------------------- K8 u_player.active_x 非常量
    got = conn(u_player, 'active_x')
    is_const = got is not None and re.match(r"^(\d+\s*'\s*[dDhHbB]\s*[0-9a-fA-F_]+|\d+)$", got) is not None
    check('K8', 'image_player.active_x 接的是 wire（不是常量 0）',
          got == 'active_x' and not is_const,
          '实际连接 = %r%s' % (got, '  ← 常量！Key9 会静默失效' if is_const else ''))

    # --------------------------------------- K9 active_x 的驱动源必须是 video_timing_gen
    got_vtg = conn(u_vtg, 'active_x')
    check('K9', 'active_x 由 video_timing_gen u_vtg 驱动（与 de 同拍的真列号）',
          got_vtg == 'active_x',
          'u_vtg.active_x = %r' % (got_vtg,))

    # ------------------------ K10 没有任何 win_* 端口接到 img_scaler 的 image_out_*
    bad = []
    for blk, nm in [(u_mask, 'u_image_mask'), (u_player, 'u_player')]:
        for port, _ in win_ports:
            got = conn(blk, port)
            if got is not None and got.startswith('image_out_'):
                bad.append('%s.%s 仍接 %s（Key9 被 img_scaler 旁路）' % (nm, port, got))
    check('K10', '两处 win_* 都没有退回接 img_scaler 的 image_out_*（防回退）',
          not bad, '; '.join(bad) if bad else 'OK')

    # -------------------------------------------------------------------- 输出
    print('=' * 78)
    print('check_key9_shared.py — Key9 双消费者「同源」结构性判据')
    print('目标: %s' % TOP)
    print('=' * 78)
    fails = 0
    for cid, desc, ok, detail in results:
        print('[%s] %s  %s' % (cid, 'PASS' if ok else 'FAIL', desc))
        if not ok:
            print('       %s' % detail)
            fails += 1
    print('-' * 78)
    if fails:
        print('RESULT: FAIL  (%d/%d 条断言不通过)' % (fails, len(results)))
        return 1
    print('RESULT: PASS  (%d/%d 条断言全部通过)' % (len(results), len(results)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
