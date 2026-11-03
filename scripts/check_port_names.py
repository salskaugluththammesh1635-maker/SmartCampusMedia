#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_port_names.py -- 命名端口交叉校验（补 ModelSim `vlog` 的盲区）

【为什么需要这个脚本】
    `vlog` 对「例化时写了模块里不存在的端口名」是**完全不报**的：
        sub u_sub (.clk(clk), .bright_sel(bright_sel), .q(q));   // 模块只有 bright_lvl
    实测 VLOG_EXIT=0、零 Error 零 Warning（2026-11-02，t7-A）。
    只有 vsim elaboration 会报：
        # ** Error: (vsim-3063) topi.v(2): Port 'bright_sel' not found in the connected module.
    但跑一次 vsim 要加载整个工程，顶层还缺 PLL/SDRAM/加密核的仿真模型 —— 所以用本脚本。

【判据】
    NO_SUCH_PORT 数量必须为 0  —— 这是唯一硬判据。
    UNKNOWN_MODULE 只有下面两个白名单成员，**属预期、不是待修项**：
        EG_PHY_SDRAM_2M_32                    原厂 SDRAM 软核（.al 里指向 ip/，源码不在 rtl/）
        hdmi_1_4b_transmitter_core_wrapper    HDMI 加密件（.enc.v，不可读）
    ★★ 请勿因为看到这两条非零就去"修"匹配逻辑或把它们删掉 ——
       它们是**故意**留着可见的，好让「真的多出一个未知模块」时能一眼看出来。
       除这两个之外出现任何 UNKNOWN_MODULE，才说明有人例化了 rtl/ 里没有的模块。
    UNCONNECTED  分两类：**意外未接**（必须看）与**预期未接**（白名单，不参与判定）。
       只有「意外未接」或「意外 UNKNOWN_MODULE」才让 EXIT=1。
    EMPTY_CONN   `.port()` 空括号 —— Verilog 合法、语义等价于「不接」（input 悬空为 z）。
       同样分**有意**（白名单）与**意外**（FAIL）。见下方【EMPTY_CONN 白名单】。

【EMPTY_CONN 白名单（EXPECTED_EMPTY）—— 第五条盲区】
    这是本脚本**最后一个补上的盲区**（captain 2026-11-02 抓到）：
        `.vol_lvl(vol_lvl)`  →  `.vol_lvl()`      RESULT: PASS / EXIT=0    ← 漏了
        整条删掉 `.vol_lvl(vol_lvl),`               RESULT: FAIL / EXIT=1    ← 能抓到
    为什么危险：`.port()` 是**合法语法**，而「偷懒修法」最自然的写法就是它。
    t7-B 若写 `.win_w()` 而不是 `.win_w(k9_win_w)`，本脚本判 PASS、`vlog` 不报、
    TD `elaborate` 也不报 → 一路绿到上板，现象是 Key9 按下画面不变（整屏黑边）。

    所以空括号**单独归一类、不计入 `used`**（从而同时进 `missing`，被 UNCONNECTED 覆盖）。
    白名单的价值不在「列出来」，而在「以后新增的空连接必须显式进白名单」——
    t7-B 每加一根线都会被这里提醒一次。**新增一条前请先在顶层写好理由注释。**

【UNCONNECTED 白名单（EXPECTED_UNCONNECTED）】
    与 UNKNOWN_MODULE 同理：一条「预期内的非零」混在提示里，人会习惯性无视整段
    UNCONNECTED —— 那时候真漏接也看不出来。所以预期未接的条目必须列进白名单，
    且**不参与判定**。

    当前成员：**无**（2026-11-02 t7-B 起）。
        曾经唯一一条是 ('gallery_probe', 'u_gallery', 'rle_fail', 'rle_found',
        'rle_lba', 'rle_size') —— t19 新增的四个输出，t7-B 例化 u_rle 时才接。
        按当初的承诺**已删除**（接完后它从「预期 4」变「意外 0」再到「无此条」）。
        空表不等于「白名单机制没了」：任何未接端口现在都会直接判 FAIL，
        新增预期未接必须显式写回这里并说明理由。

【什么时候必须跑】
    1) 任何一次改完顶层例化（端口改名 / 增删端口 / 新例化模块）之后；
    2) **跑完 `scripts\\sync_src.ps1` 之后再跑一次** —— TD 编的是 `project/hdmi/` 副本，
       副本与 `rtl/` 不一致时（同步漏了、或有人手改副本）本脚本的结论对 TD 不成立。
       （2026-11-02 踩过：改完接线跑 TD 得 PASS-elaborate，实际编的是 15:24 的旧副本。）

【用法】
    python scripts\\check_port_names.py [rtl_root] [top_file]
    默认 rtl_root=rtl/、top_file=rtl/top/dmz_eg4s20_hdmi_top.v
    退出码：0 = 全部判据干净；1 = 有 NO_SUCH_PORT / 自检失败 / 意外 UNKNOWN_MODULE / 意外未接 / 意外空连接。
"""
import os, re, sys

_HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(_HERE, 'rtl')
TOP  = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, 'top', 'dmz_eg4s20_hdmi_top.v')

def strip_comments(text):
    out = []; i = 0; n = len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n:
                if text[j] == '\\': j += 2; continue
                if text[j] == '"': break
                j += 1
            out.append(text[i:j+1]); i = j + 1; continue
        if c == '/' and i+1 < n and text[i+1] == '/':
            j = text.find('\n', i); i = n if j < 0 else j; continue
        if c == '/' and i+1 < n and text[i+1] == '*':
            j = text.find('*/', i+2); i = n if j < 0 else j+2; continue
        out.append(c); i += 1
    return ''.join(out)

DIR = re.compile(r'\b(input|output|inout)\b')

def names_from_seg(seg):
    """'wire [3:0] a, b, c' -> ['a','b','c']  (strip range/keywords/defaults)"""
    seg = re.sub(r'=[^,]*', ' ', seg)                     # drop default values
    seg = re.sub(r'\[[^\]]*\]', ' ', seg)                 # drop ranges
    seg = re.sub(r'\b(wire|reg|logic|signed|unsigned)\b', ' ', seg)
    res = []
    for part in seg.split(','):
        toks = re.findall(r'[A-Za-z_]\w*', part)
        if toks: res.append(toks[-1])
    return res

def parse_ports(plist, body):
    names = set()
    # ANSI: split plist by direction keywords; each segment belongs to that direction
    ms = list(DIR.finditer(plist))
    if ms:
        for idx, m in enumerate(ms):
            end = ms[idx+1].start() if idx+1 < len(ms) else len(plist)
            names |= set(names_from_seg(plist[m.end():end]))
        if names: return names
    # non-ANSI: bare identifiers in port list + declarations in body
    for m in re.finditer(r'\b(input|output|inout)\b', body):
        end = body.find(';', m.end())
        if end < 0: continue
        names |= set(names_from_seg(body[m.end():end]))
    if names: return names
    for t in re.findall(r'[A-Za-z_]\w*', plist):
        names.add(t)
    return names

mod_ports = {}
files = []
for dp, dn, fn in os.walk(ROOT):
    for f in fn:
        if f.endswith('.v'): files.append(os.path.join(dp, f))

for p in files:
    txt = open(p, encoding='utf-8', errors='replace').read()
    code = strip_comments(txt)
    for m in re.finditer(r'\bmodule\s+(\w+)\s*(#\s*\((?:[^()]|\([^()]*\))*\)\s*)?\(', code):
        name = m.group(1); start = m.end() - 1
        depth = 0; k = start
        while k < len(code):
            if code[k] == '(': depth += 1
            elif code[k] == ')':
                depth -= 1
                if depth == 0: break
            k += 1
        plist = code[start:k+1]
        be = code.find('endmodule', k)
        body = code[k+1: be if be > 0 else len(code)]
        mod_ports.setdefault(name, set()).update(parse_ports(plist, body))

# sanity: known ports must be present
sanity = [('image_player','rst_n_pix'), ('image_player','out_h'), ('image_player','sdram_cke'),
          ('osd_panel','bright_lvl'), ('osd_panel','vol_lvl'), ('osd_panel','ratio_sel'),
          ('osd_autopop','bright_lvl'), ('osd_autopop','res_sel'),
          ('key_router','bright_lvl'), ('video_overlay','bright_sel'),
          ('brightness_apply','de_out'), ('pix_mosaic','rgb565_out'),
          ('ratio_map','win_off_y'), ('rle_decoder','sd_grant'), ('wav_stream_player','sd_grant')]
print("=== 自检（这些端口必须被解析到） ===")
ok = True
for mod, port in sanity:
    got = port in mod_ports.get(mod, set())
    if not got: ok = False
    print("  %-20s %-14s %s" % (mod, port, "OK" if got else "*** MISSING ***"))
print("  self-check:", "PASS" if ok else "FAIL")
print()

code = strip_comments(open(TOP, encoding='utf-8', errors='replace').read())
KW = set('module endmodule input output inout wire reg logic assign always initial if else case '
         'casez casex endcase begin end for while repeat function endfunction task endtask '
         'parameter localparam integer genvar generate endgenerate posedge negedge or and not '
         'default signed unsigned'.split())

problems = []; count = 0
for m in re.finditer(r'\b(\w+)\s+(?:#\s*\((?:[^()]|\([^()]*\))*\)\s*)?(u_\w+)\s*\(', code):
    mod, inst = m.group(1), m.group(2)
    if mod in KW: continue
    if mod not in mod_ports:
        problems.append(("UNKNOWN_MODULE(IP/enc)", mod, inst, "")); continue
    start = m.end() - 1; depth = 0; k = start
    while k < len(code):
        if code[k] == '(': depth += 1
        elif code[k] == ')':
            depth -= 1
            if depth == 0: break
        k += 1
    conns = code[start+1:k]
    parts, d2, cur = [], 0, ''
    for ch in conns:
        if ch in '([{': d2 += 1
        if ch in ')]}': d2 -= 1
        if ch == ',' and d2 == 0: parts.append(cur); cur = ''
        else: cur += ch
    if cur.strip(): parts.append(cur)
    count += 1
    used = set()
    empty = set()
    for part in parts:
        # 先判「空括号连接」.port() —— Verilog 里合法，语义等价于「不接」。
        # 必须单独归一类，不能混进 used，否则 .vol_lvl() 会被当成已接。
        pe = re.match(r'\s*\.\s*(\w+)\s*\(\s*\)\s*$', part)
        if pe:
            pn = pe.group(1); empty.add(pn)
            if pn not in mod_ports[mod]:
                problems.append(("NO_SUCH_PORT", mod, inst, pn + "  (空括号但模块无此端口)"))
            continue
        pm = re.match(r'\s*\.\s*(\w+)\s*\(', part)
        if pm:
            pn = pm.group(1); used.add(pn)
            if pn not in mod_ports[mod]:
                problems.append(("NO_SUCH_PORT", mod, inst, pn))
    if empty:
        problems.append(("EMPTY_CONN", mod, inst, ",".join(sorted(empty))))
    if used or empty:
        missing = mod_ports[mod] - used - empty
        if missing:
            problems.append(("UNCONNECTED", mod, inst, ",".join(sorted(missing))))

print("modules parsed:", len(mod_ports), " instantiations scanned:", count)
print()

# 白名单：这两个不是待修项，见文件头【判据】。除它们之外的 UNKNOWN_MODULE 才是真问题。
EXPECTED_UNKNOWN = {
    'EG_PHY_SDRAM_2M_32',                   # 原厂 SDRAM 软核，源码在 ip/
    'hdmi_1_4b_transmitter_core_wrapper',   # HDMI 加密件 .enc.v
}

# 预期未接白名单：{模块名: {实例名: {端口...}}}，见文件头【UNCONNECTED 白名单】。
# ★ 2026-11-02 t7-B：u_rle 已例化、gallery_probe 的四根 rle_* 输出已接上，
#   原来那条 `gallery_probe/u_gallery {rle_lba, rle_size, rle_found, rle_fail}`
#   按注释承诺**已删除**。现在这张表为空 —— 任何未接端口都会直接判 FAIL。
#   这不是「白名单没了」，而是「当前没有任何一条是预期的」：新增预期未接
#   必须显式写在这里并说明理由，否则就是漏接。
EXPECTED_UNCONNECTED = {}

# 有意空连接白名单：{模块名: {实例名: {端口...}}}。
# 这些是**顶层写了 `.port()` 但有意不接**的地方（2026-11-02 全量核对，24 处，每处顶层都有理由注释）。
# ★ 白名单的价值不在「列出来」，而在「以后新增的空连接必须显式进白名单」——
#   t7-B 每加一根线都会被这里提醒一次。新增一条前请先在顶层写好理由注释。
EXPECTED_EMPTY = {
    'key_matrix_4x4': {
        'u_key': {'key_state'},                    # 键值走 key_event/key_code，矩阵状态无消费者
    },
    'key_router': {
        'u_keyrouter': {'audio_en', 'ticker_en',      # 被 _eff 取代（_eff 已并入 key_router 内部逻辑）
                        'osd_pop_req', 'osd_item'},   # osd_autopop 无此输入（见 §5 #7）
    },
    'player_ctrl': {
        'u_ctrl': {'mode', 'status_led'},          # mode 由 u_mode 唯一提供；板载无 status_led
    },
    'video_timing_gen': {
        'u_vtg': {'hs', 'frame_start'},            # 无消费者
    },
    'thermal_guard': {
        'u_thermal': {'oth_enter', 'oth_exit',     # 单拍沿无消费者；temp_alarm 接 oth_en 电平
                      'temp_alive'},               # 无消费者
    },
    'image_player': {
        'u_player': {
            # 【t7-B 改】ext_* 外部写通路不再是「全部禁用」：
            #   ext_wr_mode / ext_wr_valid / ext_wr_addr / ext_wr_data / ext_wr_dm /
            #   ext_wr_done / ext_no_fade / ext_wr_ack / ext_wr_busy /
            #   ext_frame_ready 十根都已接 u_rle。
            #   剩下三根仍是有意空连接：
            'ext_frame_sel',        # 2 位 output（当前前台缓冲 0=A/1=B），本层无消费者
            'ext_loader_want_blk',  # BMP 装载通路请求，ext_wr_mode=1 时恒 0，无消费者
            # 【t7-B 新增】Key9 改由 ratio_map 驱动 image_window_mask 与 pix_reader 后，
            #   img_scaler 的四个缩放结果在本层就没有消费者了（T1_TO_T7_WIRING.md §1.3）。
            #   端口不删（那是 t4/storage 的域），本层空连接。
            #   ★ 这四条是「预期空连接」而不是「漏接」—— 与上面 ext_* 的区别是：
            #     ext_* 有驱动源只是本层不消费，out_* 是「本层主动改成不消费」。
            'out_w', 'out_h', 'out_off_x', 'out_off_y',
        },
    },
    'audio_src_mux': {
        'u_audio_src': {'eff_audio_en'},           # 音量应急钳位以 key_router 为唯一权威
    },
    'wav_stream_player': {
        'u_wav': {'err_code', 'fifo_level'},       # 无消费者
    },
    'brightness_apply': {
        'u_bright': {'de_out'},                    # osd_panel.de 继续用顶层 de（de 只门控输出）
    },
    'hdmi_1_4b_transmitter_core_wrapper': {
        # 注意：本模块是加密件（UNKNOWN_MODULE），脚本在 `mod not in mod_ports` 处就跳过，
        # 不会扫描它的连接 —— 这条白名单**永远不会被命中**，保留纯粹作文档用。
        'u_hdmi_core': {'O_edid_read_valid', 'O_edid_read_data', 'O_axis_s_ready'},   # EDID 未用
    },
}

bad     = [p for p in problems if p[0] == "NO_SUCH_PORT"]
unknown = [p for p in problems if p[0].startswith("UNKNOWN_MODULE")]
unexp   = [p for p in unknown if p[1] not in EXPECTED_UNKNOWN]

unc_all = [p for p in problems if p[0] == "UNCONNECTED"]
unc_exp, unc_unexp = [], []
for p in unc_all:
    allowed = EXPECTED_UNCONNECTED.get(p[1], {}).get(p[2], set())
    ports   = set(p[3].split(','))
    if ports and ports <= allowed:
        unc_exp.append(p)          # 整条都在白名单里 → 预期未接
    elif ports & allowed:
        unc_unexp.append((p[0], p[1], p[2],
                          p[3] + "  （其中预期未接: " + ",".join(sorted(ports & allowed)) + "）"))
    else:
        unc_unexp.append(p)        # 与白名单无关 → 意外未接

emp_all = [p for p in problems if p[0] == "EMPTY_CONN"]
emp_exp, emp_unexp = [], []
for p in emp_all:
    allowed = EXPECTED_EMPTY.get(p[1], {}).get(p[2], set())
    ports   = set(p[3].split(','))
    if ports and ports <= allowed:
        emp_exp.append(p)          # 整条都在白名单里 → 有意空连接
    elif ports & allowed:
        emp_unexp.append((p[0], p[1], p[2],
                          p[3] + "  （其中白名单内: " + ",".join(sorted(ports & allowed)) + "）"))
    else:
        emp_unexp.append(p)        # 与白名单无关 → 意外空连接

print("*** NO_SUCH_PORT = %d %s ***" % (len(bad), "(全部端口名都存在)" if not bad else ""))
print("    UNKNOWN_MODULE = %d（其中预期 %d：IP/加密件；**意外 %d**）"
      % (len(unknown), len(unknown) - len(unexp), len(unexp)))
print("    UNCONNECTED    = %d（其中预期未接 %d；**意外未接 %d**）"
      % (len(unc_all), len(unc_exp), len(unc_unexp)))
print("    EMPTY_CONN     = %d 个实例 / %d 个端口（其中有意空连接 %d；**意外空连接 %d**）"
      % (len(emp_all), sum(len(p[3].split(',')) for p in emp_all), len(emp_exp), len(emp_unexp)))
print()

if unknown:
    print("--- UNKNOWN_MODULE 明细 ---")
    for p in unknown:
        tag = "预期(IP/加密件)" if p[1] in EXPECTED_UNKNOWN else "*** 意外！rtl/ 里没有这个模块 ***"
        print("  %-40s %-14s %s" % (p[1], p[2], tag))
    print()
if unc_exp:
    print("--- UNCONNECTED 预期未接（白名单，不参与判定）---")
    for p in unc_exp:
        print("  %-24s %-14s %s" % (p[1], p[2], p[3]))
    print()
if unc_unexp:
    print("--- UNCONNECTED 意外未接（逐条判断：真漏接 / 还是该进白名单）---")
    for p in unc_unexp:
        print("  %-24s %-14s %s" % (p[1], p[2], p[3]))
    print()
if emp_exp:
    print("--- EMPTY_CONN 有意空连接（白名单，不参与判定）---")
    for p in emp_exp:
        print("  %-40s %-14s {%s}" % (p[1], p[2], p[3]))
    print()
if emp_unexp:
    print("--- EMPTY_CONN 意外空连接（写了 .port() 但没接，且不在白名单里）---")
    for p in emp_unexp:
        print("  %-40s %-14s {%s}" % (p[1], p[2], p[3]))
    print()
if bad:
    print("--- NO_SUCH_PORT 明细（必须修）---")
    for p in bad:
        print("  %-24s %-14s 例化了不存在的端口 .%s()" % (p[1], p[2], p[3]))
    print()

fatal_reasons = []
if not ok:
    fatal_reasons.append("自检未通过（端口解析器本身可能坏了，本结论不可信）")
if bad:
    fatal_reasons.append("NO_SUCH_PORT = %d（例化了不存在的端口名）" % len(bad))
if unexp:
    fatal_reasons.append("意外 UNKNOWN_MODULE = %d（rtl/ 里没有这个模块）" % len(unexp))
if unc_unexp:
    fatal_reasons.append("意外 UNCONNECTED = %d（端口没接，且不在白名单里）" % len(unc_unexp))
if emp_unexp:
    fatal_reasons.append("意外 EMPTY_CONN = %d（写了 .port() 但没接，且不在白名单里）" % len(emp_unexp))

if fatal_reasons:
    print("RESULT: FAIL")
    for r in fatal_reasons:
        print("  原因: " + r)
    sys.exit(1)
print("RESULT: PASS")
sys.exit(0)
