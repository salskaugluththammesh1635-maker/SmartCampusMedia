#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""变异测试: 验证 tb_img_scaler 能否抓到 img_scaler 的真实缺陷。

每个变异体只改一处逻辑，然后跑同一套 testbench:
  KILLED   = testbench 报错（说明测试有效）
  SURVIVED = testbench 通过（说明该处逻辑未被测试覆盖）
  BAD-PATTERN = 变异体的原文本在源码里找不到（源码已改，需同步变异体）

用法:
  python scripts/mutate_scaler.py            # 全部变异体
  python scripts/mutate_scaler.py m3 m6      # 只跑指定编号

退出码: 0 = 全部 KILLED; 1 = 有存活/异常

注意: 变异体文本与 rtl/storage/img_scaler.v 的实际源码逐字符绑定。
      改过 img_scaler 后若出现 BAD-PATTERN，说明该变异体已失效，
      必须同步更新而不是忽略 —— 否则覆盖证据会静默失效。
"""
import io
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MS = r"D:\Quartus_APP\modelsim_ase\win32aloem"
SRC = os.path.join(ROOT, "rtl", "storage", "img_scaler.v")
TB = os.path.join(ROOT, "sim", "testbench", "tb_img_scaler.v")
MUT = os.environ.get("IMG_SCALER_MUTATION_DIR",
                     os.path.join(ROOT, "sim", "mut_scaler"))

# (名字, 说明, [(原文本, 替换文本), ...])
MUTANTS = [
    ("m1", "去掉自底向上的行镜像",
     [("? (bot_now ? (dst_h_r - 16'd1 - out_row) : out_row)",
       "? out_row")]),

    ("m2", "列相位与列计数在新行时不重置",
     [("wire [16:0] cp_eff  = new_row ? ({1'b0, c_thr} - 17'd1) : col_phase;",
       "wire [16:0] cp_eff  = col_phase;"),
      ("wire [15:0] col_eff = new_row ? 16'd0 : out_col;",
       "wire [15:0] col_eff = out_col;")]),

    ("m3", "相位初值改 0（首行/首列被误丢）",
     [("wire [16:0] rp_eff   = first_row ? ({1'b0, r_thr} - 17'd1) : row_phase;",
       "wire [16:0] rp_eff   = first_row ? 17'd0 : row_phase;"),
      ("wire [16:0] cp_eff  = new_row ? ({1'b0, c_thr} - 17'd1) : col_phase;",
       "wire [16:0] cp_eff  = new_row ? 17'd0 : col_phase;")]),

    ("m4", "方向判定恒为自顶向下",
     [("wire        bot_now  = dir_known ? bottom_up : (src_y != 16'd0);",
       "wire        bot_now  = 1'b0;")]),

    ("m5", "居中偏移算错（漏掉除 2）",
     [("out_off_x  <= ((DSTW - dw_c) >> 1) & 16'hFFF8;",
       "out_off_x  <= (DSTW - dw_c) & 16'hFFF8;")]),

    ("m6", "dst_w 不强制 8 像素对齐（破坏仲裁器四字突发组）",
     [("            dw_c = {dw_c[15:3], 3'b000};        // 强制 8 像素对齐（见上方说明）\n"
       "            if (dw_c == 16'd0) dw_c = 16'd8;",
       "            if (dw_c == 16'd0) dw_c = 16'd8;")]),

    ("m7", "1:1 模式不居中（偏移恒 0）",
     [("out_off_y  <= (DSTH - src_h_r) >> 1;",
       "out_off_y  <= 16'd0;")]),

    ("m8", "模式判据用错比较方向",
     [("wire        wide       = (src_w_x480 > src_h_x640);",
       "wire        wide       = (src_w_x480 < src_h_x640);")]),

    ("m9", "行采样参数错用列参数（行列共用一组）",
     [("r_step     <= dh_c;\n"
       "                        r_thr      <= src_h_r;",
       "r_step     <= dw_c;\n"
       "                        r_thr      <= src_w_r;")]),

    ("m10", "列采样参数错用行参数（行列共用一组）",
     [("c_step     <= dw_c;\n"
       "                        c_thr      <= src_w_r;",
       "c_step     <= dh_c;\n"
       "                        c_thr      <= src_h_r;")]),

    ("m11", "列相位减错阈值（用行阈值）",
     [("col_phase <= col_hit ? (cp_sum - {1'b0, c_thr}) : cp_sum;",
       "col_phase <= col_hit ? (cp_sum - {1'b0, r_thr}) : cp_sum;")]),

    ("m12", "零尺寸源图仍被发布为有效缩放配置",
     [("end else if (div_vld && (src_w_r != 16'd0) &&\n"
       "                                             (src_h_r != 16'd0)) begin",
       "end else if (div_vld) begin")]),
]


def run(cmd, cwd):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def main():
    only = set(a.lower() for a in sys.argv[1:])

    with io.open(SRC, "r", encoding="utf-8") as f:
        base = f.read()

    if not os.path.isdir(MUT):
        os.makedirs(MUT)

    results = []
    for name, desc, subs in MUTANTS:
        if only and name.lower() not in only:
            continue
        text = base
        ok = True
        for old, new in subs:
            if old not in text:
                results.append((name, desc, "BAD-PATTERN", "pattern not found"))
                ok = False
                break
            text = text.replace(old, new, 1)
        if not ok:
            continue

        mpath = os.path.join(MUT, name + ".v")
        with io.open(mpath, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)

        wd = os.path.join(MUT, "w_" + name)
        if os.path.isdir(wd):
            shutil.rmtree(wd)
        os.makedirs(wd)

        rc, out = run([os.path.join(MS, "vlib.exe"), "work"], wd)
        rc, out = run([os.path.join(MS, "vlog.exe"), "-quiet", mpath, TB], wd)
        if "Error" in out:
            results.append((name, desc, "COMPILE-ERROR",
                            out.strip().splitlines()[0][:120]))
            continue

        rc, out = run([os.path.join(MS, "vsim.exe"), "-c", "-quiet",
                       "-onfinish", "stop",
                       "-do", "run -all; quit -f -code 0",
                       "work.tb_img_scaler"], wd)

        if "CHECKS FAILED" in out:
            verdict = "KILLED"
        elif "ALL CHECKS PASSED" in out:
            verdict = "SURVIVED"
        else:
            verdict = "NO-VERDICT"
        m = re.search(r"SUMMARY: checks=(\d+) errors=(\d+)", out)
        detail = m.group(0) if m else "no summary"
        results.append((name, desc, verdict, detail))

    print("=" * 78)
    print("变异测试结果（KILLED = 测试有效捕获；SURVIVED = 覆盖缺口）")
    print("=" * 78)
    surv = 0
    for name, desc, verdict, detail in results:
        print("%-4s %-10s %-32s %s" % (name, verdict, desc, detail))
        if verdict != "KILLED":
            surv += 1
    print("-" * 78)
    print("变异体 %d 个，被捕获 %d 个，存活/异常 %d 个"
          % (len(results), len(results) - surv, surv))
    return 0 if surv == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
