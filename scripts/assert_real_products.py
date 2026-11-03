# -*- coding: utf-8 -*-
"""A1 自检：用真实产物喂断言逻辑，5 秒内出结论（不 import_device / 不 open_project / 不碰 .al / 不碰 .v）。

对应 captain 的 A1「断言假报」四形态：
  (1) 格式漂移 —— 正则要求 `#bram N / M`，TD 实吐 `#bram 37 out of 64`；
  (2) 运行时加载旧脚本 —— 磁盘版 mtime 晚于该趟运行启动时刻；
  (3) 读错文件 —— `#slices` 不在面积报告里，在 gate/place/route.qor；
  (4) 引用过期同名报告 —— 报告文件被后续运行覆盖，引用的不是最终位流那一版。

本脚本对**已存在的真实报告**跑断言，因此"跑红"一定意味着断言逻辑或产物有问题，
不会被 13 分钟的 TD 流程搅混。同时它自己也带反证：对每条判据都喂一份
**已知会失败**的合成输入，若那条反证不红，说明判据本身没在工作。

用法：
    python scripts\\assert_real_products.py
退出码 0 = 全部判据对真实产物成立且四条反证全部变红；1 = 有问题。
"""
from __future__ import annotations

import io
import os
import re
import sys

# reports/ 与 project/ 都在仓库根 SmartCampusMedia/ 下（不是它的父目录 FPGA_Compelate/）
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
REPORTS = os.path.join(ROOT, 'reports')
PROJECT = os.path.join(ROOT, 'project')

# ---------------------------------------------------------------------------
# 断言逻辑（与 project\\t7b_assert_only.tcl 的 check_area / check_timing /
# check_qor 逐条对应，用 Python 复写，便于在这里做反证）
# ---------------------------------------------------------------------------

RE_BRAM = re.compile(r'#bram\s+([0-9]+)\s*(?:/|out\s+of)\s*([0-9]+)')
RE_LUT = re.compile(r'#lut\s+([0-9]+)\s*(?:/|out\s+of)\s*([0-9]+)')
RE_SLICES_AREA = re.compile(r'#slices\s+([0-9]+)\s*(?:/|out\s+of)\s*([0-9]+)\s*\(\s*([0-9.]+)%\s*\)')
RE_SLICES_QOR = re.compile(r'\|\s*#slices\s*\|\s*([0-9]+)\s*\|')
RE_SLICES_PCT_QOR = re.compile(r'\|\s*slices percentage\s*\|\s*([0-9.]+)%')
RE_SWNS = re.compile(r'SWNS:\s+(-?[0-9.]+)ns,\s*STNS:')
RE_HWNS = re.compile(r'HWNS:\s+(-?[0-9.]+)ns,\s*HTNS:')

# 基线门槛（与 t9 契约一致；改动必须在这里改，不要散落在判据里）
MIN_BRAM = 35          # 位流含 cjk 字库 + pix_fifo 换 BRAM 后，BRAM 不应低于 35
MAX_LUT = 19600        # 器件硬上限


def read(path: str) -> str:
    return io.open(path, encoding='utf-8', errors='replace').read()


def check_area(text: str) -> dict:
    """面积报告判据。返回 {'ok':bool, 'msgs':[...], 'vals':{...}}。"""
    msgs, vals, ok = [], {}, True
    m = RE_BRAM.search(text)
    if not m:
        msgs.append('ERR AREA_NO_BRAM（#bram 行没匹配上：格式漂移？）')
        ok = False
    else:
        vals['bram'] = (int(m.group(1)), int(m.group(2)))
        if int(m.group(1)) < MIN_BRAM:
            msgs.append('ERR BRAM_REGRESSED: %d < %d' % (int(m.group(1)), MIN_BRAM))
            ok = False
    m = RE_LUT.search(text)
    if not m:
        msgs.append('ERR AREA_NO_LUT（#lut 行没匹配上）')
        ok = False
    else:
        vals['lut'] = (int(m.group(1)), int(m.group(2)))
        if int(m.group(1)) > MAX_LUT:
            msgs.append('ERR LUT_OVER: %d > %d' % (int(m.group(1)), MAX_LUT))
            ok = False
    m = RE_SLICES_AREA.search(text)
    if m:
        vals['slices'] = (int(m.group(1)), int(m.group(2)), float(m.group(3)))
    else:
        # 非致命：report_area 本来就不吐 #slices（A1 第 3 形态）
        msgs.append('INFO AREA_NO_SLICES（面积报告不含 #slices，这是正常的；去 .qor 读）')
    return {'ok': ok, 'msgs': msgs, 'vals': vals}


def check_timing(text: str) -> dict:
    msgs, vals, ok = [], {}, True
    m = RE_SWNS.search(text)
    if not m:
        msgs.append('ERR TIMING_NO_SWNS（SWNS 行没匹配上）')
        ok = False
    else:
        vals['swns'] = float(m.group(1))
        if vals['swns'] < 0:
            msgs.append('ERR TIMING_SWNS_NEG: %.3f < 0' % vals['swns'])
            ok = False
    m = RE_HWNS.search(text)
    if not m:
        msgs.append('ERR TIMING_NO_HWNS（HWNS 行没匹配上）')
        ok = False
    else:
        vals['hwns'] = float(m.group(1))
        if vals['hwns'] < 0:
            msgs.append('ERR TIMING_HWNS_NEG: %.3f < 0' % vals['hwns'])
            ok = False
    return {'ok': ok, 'msgs': msgs, 'vals': vals}


def check_qor(text: str) -> dict:
    msgs, vals, ok = [], {}, True
    m = RE_SLICES_QOR.search(text)
    if not m:
        msgs.append('ERR QOR_NO_SLICES（| #slices | N | 没匹配上）')
        ok = False
    else:
        vals['slices'] = int(m.group(1))
    m = RE_SLICES_PCT_QOR.search(text)
    if not m:
        msgs.append('ERR QOR_NO_SLICES_PCT（| slices percentage | P% | 没匹配上）')
        ok = False
    else:
        vals['slices_pct'] = float(m.group(1))
    return {'ok': ok, 'msgs': msgs, 'vals': vals}


# ---------------------------------------------------------------------------
# 反证：每条判据都要能被一份"已知有问题"的输入打红
# ---------------------------------------------------------------------------

REFUTE_CASES = [
    # (说明, 判据函数, 合成输入, 期望出现的错误串)
    ('A1-1 格式漂移：把 "out of" 改回 "/" 之外的旧格式，bram 判据必须报 NO_BRAM',
     check_area,
     '#lut 16414 out of 19600 83.74%\n#bram                      37   of     64\n',
     'AREA_NO_BRAM'),
    ('A1-2 BRAM 回退：bram=17 必须报 REGRESSED',
     check_area,
     '#lut 16414 out of 19600\n#bram 17 out of 64 26.56%\n',
     'BRAM_REGRESSED'),
    ('A1-3 LUT 超限：lut=20000 必须报 LUT_OVER',
     check_area,
     '#lut 20000 out of 19600\n#bram 37 out of 64\n',
     'LUT_OVER'),
    ('A1-4 setup 违例：SWNS=-0.194 必须报 SWNS_NEG',
     check_timing,
     'SWNS: -0.194ns, STNS: -0.215ns\nHWNS: 0.011ns, HTNS: 0.000ns\n',
     'TIMING_SWNS_NEG'),
    ('A1-5 hold 违例：HWNS=-0.011 必须报 HWNS_NEG',
     check_timing,
     'SWNS: 0.113ns, STNS: 0.000ns\nHWNS: -0.011ns, HTNS: 0.000ns\n',
     'TIMING_HWNS_NEG'),
    ('A1-6 qor 缺 #slices 行必须报 QOR_NO_SLICES',
     check_qor,
     '| slices percentage | 87.66% |\n',
     'QOR_NO_SLICES'),
]


def refute_all() -> bool:
    all_ok = True
    print('=== 反证：每条判据都必须被已知有问题的输入打红 ===')
    for desc, fn, fake, expect in REFUTE_CASES:
        r = fn(fake)
        hit = any(expect in m for m in r['msgs'])
        red = (not r['ok']) and hit
        print('  [%s] %s' % ('PASS' if red else 'FAIL', desc))
        if not red:
            print('        ok=%s msgs=%s' % (r['ok'], r['msgs']))
            all_ok = False
    return all_ok


# ---------------------------------------------------------------------------
# 真实产物
# ---------------------------------------------------------------------------

def main() -> int:
    print('=== 判据对真实产物（只读文件，不跑 TD） ===')
    targets = [
        ('area   seed7', check_area, os.path.join(REPORTS, 't7b_seed_seed7_area.txt')),
        ('timing seed7', check_timing, os.path.join(REPORTS, 't7b_seed_seed7_timing.txt')),
        ('qor    route', check_qor, os.path.join(PROJECT, 'route.qor')),
        ('qor    place', check_qor, os.path.join(PROJECT, 'place.qor')),
    ]
    real_ok = True
    for tag, fn, path in targets:
        if not os.path.exists(path):
            print('  [FAIL] %-14s 文件不存在: %s' % (tag, path))
            real_ok = False
            continue
        r = fn(read(path))
        st = os.stat(path)
        import datetime
        mt = datetime.datetime.fromtimestamp(st.st_mtime).strftime('%Y-%m-%d %H:%M:%S')
        print('  [%s] %-14s %s  (%d B, %s)' % ('PASS' if r['ok'] else 'FAIL', tag, r['vals'], st.st_size, mt))
        for m in r['msgs']:
            print('        ' + m)
        if not r['ok']:
            real_ok = False

    print()
    ref_ok = refute_all()

    print()
    print('真实产物判据: %s' % ('PASS' if real_ok else 'FAIL'))
    print('反证（判据自身有效）: %s' % ('PASS' if ref_ok else 'FAIL'))
    verdict = real_ok and ref_ok
    print('RESULT: %s' % ('PASS' if verdict else 'FAIL'))
    return 0 if verdict else 1


if __name__ == '__main__':
    sys.exit(main())
