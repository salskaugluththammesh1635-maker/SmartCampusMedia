#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 assets/v2/masters/font/ 的 16x16 中文点阵源数据（**只做数据，不做 RTL**）。

为什么需要这份数据
------------------
现有 OSD 字库 rtl/osd/osd_font8x16.v 只有 8x16 的**英文/数字**字模（41 个字符），
拼得出 "PLAY" "IMG 05/12"，但拼不出「日常」「科普」「应急」「高温报警」这些中文。
本脚本把项目实际要显示的中文渲染成 16x16 点阵，导出为**纯数据文件**，
供后续 RTL 阶段（t5/t6/t7）按需封装成 ROM 模块 —— 本任务不写 RTL。

字符集怎么来的（不是拍脑袋凑数）
------------------------------
不手工罗列汉字，而是**从项目真实的 OSD 文案反推**：把三种模式、六个场景、
状态量、控制项、媒体操作写成短语表 `OSD_PHRASES`，展开去重后得到字符集。
这样字库里每一个字都对应屏幕上真实会出现的一处文本，不会白占 ROM。

字形来源与授权
--------------
栅格化自 **Noto Sans SC**（C:\\Windows\\Fonts\\NotoSansSC-VF.ttf），SIL Open Font
License 1.1。**刻意不用微软雅黑(msyh)/黑体(simhei)/等线(Deng)**：这三者是微软
专有字体，随工程分发其点阵有授权风险。项目已有先例
docs/science_font_attribution.md + docs/OFL-NotoSansSC.txt，本脚本与之保持一致。
运行时**不加载任何字体文件**，只分发栅格化后的点阵常量。

数据格式（与既有 science_font16.v 一致，便于后续直接对接）
--------------------------------------------------------
每个字形 16 行，每行一个 **16 bit** 整数，**bit15 = 最左像素**，bit0 = 最右。
字形索引 0..N-1 按字符集顺序编号。导出三种载体：
  cjk16_bitmap.hex    —— 每行一个 4 位十六进制字（row-major），可直接 $readmemh
  cjk16_bitmap.json   —— 带元数据的完整数据（字符、码位、每行位图、统计）
  cjk16_charset.txt   —— 索引 ↔ 字符对照表，人读
  cjk16_preview.png   —— 全部字形的可视化拼版，供目视核对字形没糊/没切边

自检项（脚本内打印）
-------------------
  1. 每个字形非空（墨点数 > 0）；
  2. 墨点率在合理区间（默认 3%~45%，过稀=没渲染出来，过密=糊成块）；
  3. 无切边（点阵最外一圈不应有墨点，否则说明字号偏大被裁掉了）；
  4. 字形互不相同（两两比较，发现重复即报错——重复意味着某字没渲染对）；
  5. 从导出的 .hex **回读**重建位图，与内存中的位图逐位比对（验证导出无损）；
  6. 用 Pillow 重新打开 preview.png 校验尺寸。

用法
----
    python scripts/gen_assets_v2_font.py
    python scripts/gen_assets_v2_font.py --art      # 额外打印 ASCII art 目视核对
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

REPO_ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = REPO_ROOT / "assets" / "v2" / "masters" / "font"

FONT_PATH = Path(r"C:\Windows\Fonts\NotoSansSC-VF.ttf")
FONT_LICENSE = "SIL Open Font License 1.1"
FONT_FAMILY = "Noto Sans SC"

CELL_W = 16
CELL_H = 16
FONT_SIZE = 15        # 16x16 格子 + 墨迹包围盒居中（见 render_glyph），15 号字墨迹约 15px
THRESHOLD = 96        # 抗锯齿灰度二值化阈值（0..255）

# **关键**：NotoSansSC-VF.ttf 是可变字体（variation font），其 Weight 轴范围
# 100~900、**默认实例是 100 (Thin)**。直接 ImageFont.truetype 得到的是 Thin，
# 笔画只有 1px 宽，16x16 下字形立不住（实测「模」只有 69 个墨点，汉字骨架
# 几乎不成形）。
#
# 字重选择是逐档目视比对出来的，不是随手取中间值：
#   可用的**命名实例**只有 Thin / Light / Regular / Medium / Bold / Black
#   —— **没有 SemiBold**（set_variation_by_name('SemiBold') 抛 ValueError）。
#   以笔画最密集的「幕 播 慧 智 园 模」六字为样本，在 16x16 下栅格化比对墨点数：
#     Thin      69~  (笔画 1px，骨架断裂)
#     Regular   83~105  ← 结构清晰、有留白，汉字可辨
#     Medium   102~121  (偏重，部分横画开始并笔)
#     Bold     131~146  (糊连：「幕」顶部成实心横条、「播」「慧」笔画粘连)
#   故选 Regular。16x16 小格下过重的字重只会牺牲可读性。
FONT_WEIGHT_NAME = "Regular"

# 项目真实 OSD 文案 -> 反推字符集。改这里就等于改字库，脚本会自动去重。
OSD_PHRASES = [
    # 三种工作模式
    "日常模式", "科普模式", "应急模式",
    # 六个校园场景（与 generate_campus_media.py 的 SCENES 一致）
    "智慧校园", "书香校园", "创客工坊", "绿色校园", "运动嘉年华", "平安校园",
    # 环境与报警（AHT20 高温联动）
    "温度", "湿度", "高温报警", "环境正常", "摄氏度",
    # 显示控制项
    "亮度", "音量", "分辨率", "屏占比", "滚动字幕", "音频可视化",
    "开关", "开启", "关闭", "第档", "档",
    # 媒体操作
    "图片", "视频", "音乐", "播放", "暂停", "上一张", "下一张",
    # 常用连接/状态
    "正在加载", "请稍候", "无信号", "系统启动",
]

# 额外单字符（标点/单位），不参与短语但屏幕要用
EXTRA_CHARS = list("0123456789℃%：")

# ============================================================================
# 【索引冻结契约】LEGACY_CHARS —— 索引 0..94 的 95 个字形，**永久冻结**
# ============================================================================
# 为什么必须硬编码而不是继续用 build_charset() 推导：
#   build_charset() 的结果依赖 OSD_PHRASES 的字面内容。任何人往 OSD_PHRASES
#   里加/改/删一个字，后续所有索引都会整体平移，而 cjk16_font.v 一旦被 RTL
#   以 index 硬引用，平移就会**静默显示错字**（不报错、不变红，只是字不对），
#   这是最难定位的一类故障。
#
#   因此把前 95 个字符冻成常量：OSD_PHRASES 再怎么改，0..94 永远不变，
#   新字只从 95 往后追加。main() 里有断言校验本常量与 LEGACY_CHARS 长度、
#   以及与既有 .hex 前 1520 行逐位一致（防渲染参数漂移）。
LEGACY_CHARS = list(
    "日常模式科普应急智慧校园书香创客工坊绿色运动嘉年华平安温度湿高报警"
    "环境正摄氏亮音量分辨率屏占比滚字幕频可视化开关启闭第档图片乐播放暂停"
    "上一张下在加载请稍候无信号系统0123456789℃%："
)
assert len(LEGACY_CHARS) == 95, f"LEGACY_CHARS 必须正好 95 个（实际 {len(LEGACY_CHARS)}）"

# ============================================================================
# 【扩容来源】实际要用到的中文，全部来自磁盘上的真实文本，不靠估算
# ============================================================================
# 为什么要读文件而不是在脚本里再写一份文案：
#   文案会改，字库必须跟着改；把文案作为唯一真源，脚本每次运行重新求并集，
#   就不会出现「文案改了、字库忘了同步 → 上屏方块」这种脱节。
TEXT_SOURCES = [
    # (路径, 说明) 相对仓库根
    ("assets/v2/sdcard/COMMON/SRT/NARR.SRT", "科普模式旁白字幕"),
    ("assets/v2/masters/text/campus_ticker.txt", "6 张校园图的校园介绍滚动文案"),
    ("assets/v2/masters/text/emergency_ticker.txt", "应急模式消防通道提示文案"),
    ("assets/v2/masters/text/ui_strings.txt", "UI 固定文案（模式/参数/档位/单位）"),
]

# 控制字符与空格不算需求：
#   \n\r\t 是排版控制符，不是要显示的字形；
#   半角空格（U+0020）虽然出现在文案里，但 OSD 对空格的正确渲染就是"什么都不画"，
#   给它存一份 16x16 全零点阵纯属浪费 ROM（32 B/字），而且会让"无空字形"自检
#   恒假——那不是发现了问题，是自检判据本身搞错了对象。
_SKIP_CHARS = {"\n", "\r", "\t", " "}


def collect_required_chars() -> tuple[list[str], dict[str, set[str]]]:
    """从 TEXT_SOURCES + OSD_PHRASES 求出**实际要用到的字符全集**。

    返回 (有序全集, {来源名: 该来源的字符集})。
    有序全集的前 95 个**必定**等于 LEGACY_CHARS（冻结契约），新增字按 Unicode
    码位排序追加在 95 之后 —— 排序而非文件出现顺序，是为了让 charset.txt 可
    人工查阅，且同一批新增字在不同文案顺序下得到相同索引。
    """
    per_source: dict[str, set[str]] = {}

    osd = set()
    for phrase in OSD_PHRASES:
        osd |= set(phrase) - _SKIP_CHARS
    per_source["OSD_PHRASES"] = osd

    extra = set()
    for ch in EXTRA_CHARS:
        if ch not in osd:
            extra.add(ch)
    per_source["EXTRA_CHARS"] = extra

    for rel, desc in TEXT_SOURCES:
        p = REPO_ROOT / rel
        if not p.is_file():
            # 文案还没落盘时不能让整个字库生成失败，但必须**显式告警**，
            # 否则会出现「脚本跑成功了、字幕却是方块」的静默缺字。
            print(f"  [WARN] 文本来源缺失，其字符未纳入字库：{rel}")
            per_source[desc] = set()
            continue
        per_source[desc] = set(p.read_text(encoding="utf-8")) - _SKIP_CHARS

    required = set()
    for s in per_source.values():
        required |= s
    # 冻结段必须在全集里，否则说明 LEGACY 有字已经没人用（保留它，索引不能动）
    required |= set(LEGACY_CHARS)

    tail = sorted(required - set(LEGACY_CHARS))
    return list(LEGACY_CHARS) + tail, per_source


def build_charset() -> list[str]:
    """历史接口：仅按 OSD_PHRASES 推导出的**冻结 95 字**。

    扩容后真源是 collect_required_chars()。本函数保留是为了兼容外部调用方
    （t3 时期有其他脚本 import 过），返回值恒等于 LEGACY_CHARS。
    """
    return list(LEGACY_CHARS)


def load_font(size: int):
    """加载字体并**显式设置可变字体的字重**，返回 (font, 实际字重名)。

    为什么必须设字重：NotoSansSC-VF.ttf 的 Weight 轴默认实例是 100 (Thin)。
    不设的话汉字笔画只有 1px 宽，16x16 下字形立不住。

    **失败必须显式报错，不能静默降级**（本脚本开发期的真实教训）：
    最初写 `except Exception: pass` 回退到默认字重，而默认恰好是 Thin，
    于是 set_variation_by_name('SemiBold') 抛的 ValueError 被吞掉，字库
    在"看起来跑成功了"的情况下退化成细体 —— 这种静默降级比直接失败更危险。
    现在：字体不支持可变轴就报错退出；命名实例不存在就列出可用的再退出。
    """
    font = ImageFont.truetype(str(FONT_PATH), size)
    try:
        axes = font.get_variation_axes()
    except Exception:
        raise SystemExit(
            f"字体 {FONT_PATH.name} 不支持可变字重轴，无法设置 {FONT_WEIGHT_NAME}。\n"
            f"请改用固定字重的字体文件，或把 FONT_WEIGHT_NAME 置空并接受默认字重。")
    try:
        font.set_variation_by_name(FONT_WEIGHT_NAME)
    except Exception as exc:
        # 列出该字体真实可用的命名实例，便于排错（Noto Sans SC 就没有 SemiBold）
        available = []
        for name in ("Thin", "Light", "Regular", "Medium", "SemiBold",
                     "Bold", "Black"):
            try:
                font.set_variation_by_name(name)
                available.append(name)
            except Exception:
                pass
        font.set_variation_by_name("Regular")
        raise SystemExit(
            f"字体没有名为 {FONT_WEIGHT_NAME} 的实例（{type(exc).__name__}）。\n"
            f"该字体可用的命名实例：{available}\n"
            f"请把 FONT_WEIGHT_NAME 改成其中之一。")
    return font, font.getname()[1]


def render_glyph(font, ch: str) -> tuple[list[int], dict]:
    """把一个字符渲染成 16 行 x 16 列的位图（每行一个 16 bit 整数，bit15=最左）。

    对齐策略：**墨迹包围盒居中**，而不是依赖字体锚点。
    为什么不用 anchor="mm"/"ma"
    ----------------------------
    中文字形的设计外框几乎顶满 1em，而 Pillow 的 mm/ma 锚点按字体度量
    (ascent/descent) 定位，Noto Sans SC 的度量与实际墨迹并不重合：
      - anchor="mm" 时下缘被挤出格子 —— 实测 14 个字（科/普/书/环/境/摄/
        屏/可/开/启/档/停/请/信）底横被裁；
      - anchor="ma" 时虽不裁边，但「日」「式」的底横紧贴第 15 行，重心偏下。
    改成：先在大画布上渲染 -> 求真实墨迹 bbox -> 把 bbox 居中放进 16x16。
    这样字形无论字体度量如何，都保证**完整不被裁**且视觉居中。

    返回值第二个元素是度量信息，供自检判断是否真的发生了裁字
    （墨迹本身大于 16x16 才算裁字；墨迹正好铺满 16x16 是合法的）。
    """
    pad = 8
    canvas = Image.new("L", (CELL_W + pad * 2, CELL_H + pad * 2), 0)
    draw = ImageDraw.Draw(canvas)
    draw.text((canvas.width / 2.0, canvas.height / 2.0), ch,
              font=font, fill=255, anchor="mm")
    bbox = canvas.getbbox()          # 真实墨迹范围（含抗锯齿像素）
    if bbox is None:
        return [0] * CELL_H, {"ink_w": 0, "ink_h": 0, "clipped": False}
    ink = canvas.crop(bbox)
    iw, ih = ink.size
    # 墨迹大于格子 = 真的会被裁掉（这是必须报错的缺陷，不是留白问题）
    clipped = iw > CELL_W or ih > CELL_H
    # 居中：整格留白平均分配（左/右、上/下）
    ox = max((CELL_W - iw) // 2, 0)
    oy = max((CELL_H - ih) // 2, 0)
    cell = Image.new("L", (CELL_W, CELL_H), 0)
    cell.paste(ink, (ox, oy))
    px = cell.load()
    rows = []
    for y in range(CELL_H):
        bits = 0
        for x in range(CELL_W):
            if px[x, y] >= THRESHOLD:
                bits |= 1 << (CELL_W - 1 - x)     # 最左像素是 MSB
        rows.append(bits)
    return rows, {"ink_w": iw, "ink_h": ih, "clipped": clipped}


def ink_stats(rows: list[int]) -> dict:
    total = 0
    edge = 0
    for y, bits in enumerate(rows):
        for x in range(CELL_W):
            if (bits >> (CELL_W - 1 - x)) & 1:
                total += 1
                if x == 0 or x == CELL_W - 1 or y == 0 or y == CELL_H - 1:
                    edge += 1
    return {"ink": total, "ink_pct": round(total / (CELL_W * CELL_H) * 100.0, 2),
            "edge_ink": edge}


def ascii_art(rows: list[int]) -> str:
    return "\n".join(
        "".join("#" if (bits >> (CELL_W - 1 - x)) & 1 else "." for x in range(CELL_W))
        for bits in rows)


def emit_preview(table: list[dict], path: Path, cols: int = 16, scale: int = 2):
    """把所有字形拼成一张预览图，供人眼确认没有糊字/切边。"""
    n = len(table)
    rows_n = (n + cols - 1) // cols
    pad = 4
    cw = CELL_W * scale + pad
    ch = CELL_H * scale + pad + 12      # 底部留一行写索引
    img = Image.new("RGB", (cols * cw + pad, rows_n * ch + pad), (18, 22, 30))
    draw = ImageDraw.Draw(img)
    try:
        label_font = ImageFont.truetype(str(FONT_PATH), 11)
    except Exception:
        label_font = ImageFont.load_default()
    for i, g in enumerate(table):
        cx = pad + (i % cols) * cw
        cy = pad + (i // cols) * ch
        for y, bits in enumerate(g["rows"]):
            for x in range(CELL_W):
                if (bits >> (CELL_W - 1 - x)) & 1:
                    draw.rectangle([cx + x * scale, cy + y * scale,
                                    cx + x * scale + scale - 1,
                                    cy + y * scale + scale - 1],
                                   fill=(232, 238, 246))
        draw.text((cx, cy + CELL_H * scale + 1), f"{i}", font=label_font,
                  fill=(120, 160, 200))
    img.save(path)
    return img.size


def emit_verilog(table: list[dict], path: Path, weight: str) -> dict:
    """导出 Verilog case 表 ROM（工程惯例，TD 对 case 推断 ROM 更稳）。

    与 rtl/osd/osd_font8x16.v、rtl/video/science_font16.v 保持同一种数据形态：
    每行 16 bit、bit15 = 最左像素、索引 = {glyph_index, row}。
    **本任务只产出数据文件，不接入任何 RTL 层次**（接线由 t5/t6/t7 决定）。
    """
    n = len(table)
    gbits = max(1, (n - 1).bit_length())      # 覆盖 0..n-1 所需位宽
    total_bits = n * 16 * 16
    lines = []
    a = lines.append
    a("// ============================================================================")
    a("// 文件名  : cjk16_font.v")
    a("// 所在位置: assets/v2/masters/font/cjk16_font.v  （母版数据，尚未接入 rtl/）")
    a("// 所属层次: OSD 层 / 16x16 中文点阵字模 ROM（数据源，供后续 RTL 阶段接入）")
    a("// ============================================================================")
    a("// 【一】本文件是什么")
    a(f"//   {n} 个中文/全角字形，每个 16x16 点阵，每行 16 bit（bit15 = 最左像素），")
    a("//   共 16 行。给 {字形索引, 行号} 返回该行的 16 个像素。")
    a("//   纯组合查表，无时钟、无状态，同拍出图。")
    a("")
    a("// 【二】为什么是 16x16")
    a("//   现有 rtl/osd/osd_font8x16.v 只有 8x16 的英文/数字，拼不出「日常模式」")
    a("//   「高温报警」这类中文。16x16 是 640x480 下单行中文可读的最小粒度：")
    a("//   8x8 的汉字笔画会粘连，实测不可辨认。")
    a("")
    a("// 【三】字形来源与许可")
    a(f"//   栅格化自 {FONT_FAMILY} {weight}（{FONT_LICENSE}），")
    a("//   **刻意不用微软雅黑/黑体/等线**（微软专有字体，随工程分发点阵有授权风险）。")
    a("//   项目授权说明见 docs/science_font_attribution.md 与 docs/OFL-NotoSansSC.txt。")
    a("//   运行时**不加载任何字体文件**，只分发本文件的点阵常量。")
    a("")
    a("// 【四】重新生成")
    a("//   python scripts/gen_assets_v2_font.py")
    a("//   生成脚本自带自检：无空字形 / 墨点率合理 / 无切边 / 字形互不相同 /")
    a("//   .hex 回读逐位一致 / preview.png 可重新打开。")
    a("")
    a("// 【五】资源代价")
    a(f"//   {n} 字形 x 16 行 x 16 bit = {total_bits:,} bit 常量。")
    a("//   综合成 LUT 查表（不用 BRAM：BRAM 读延迟 1 拍，OSD 需与像素同拍组合）。")
    a("//   注意：接入 RTL 前请与 rtl-engineer 确认字库容量预算（BRAM9K/LUT 余量）。")
    a("")
    a("// 【六】索引约定")
    a(f"//   glyph 位宽 {gbits} bit（覆盖 0..{n - 1}），row 位宽 4 bit（0..15，0 = 最上行）。")
    a(f"//   未收录索引走 default 输出 16'h0000（屏幕表现为空白，不会画出乱码）。")
    a("//   索引 ↔ 字符对照见同目录 cjk16_charset.txt。")
    a("// ============================================================================")
    a(f"module cjk16_font (")
    a(f"    input  wire [{gbits - 1}:0] glyph,   // 字形索引 0..{n - 1}")
    a(f"    input  wire [3:0] row,       // 行号 0..15（0 = 最上一行）")
    a(f"    output reg  [15:0] pixels    // 该行 16 个像素，bit15 = 最左")
    a(");")
    a("")
    a("    always @(*) begin")
    a("        pixels = 16'h0000;         // 默认空白（未收录字形显示为空）")
    a("        case ({glyph, row})")
    for g in table:
        label = g["char"] if g["char"].strip() else "space"
        a(f"            // {g['index']}: {label}")
        for y, bits in enumerate(g["rows"]):
            key = (g["index"] << 4) | y
            a(f"            {gbits + 4}'d{key}: pixels = 16'h{bits:04X};")
    a("            default: pixels = 16'h0000;")
    a("        endcase")
    a("    end")
    a("")
    a("endmodule")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    return {"glyphs": n, "glyph_bits": gbits, "constants": n * 16,
            "total_bits": total_bits, "lines": len(lines)}


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--art", action="store_true", help="打印 ASCII art 供目视核对")
    ap.add_argument("--out", type=Path, default=OUT_DIR)
    args = ap.parse_args()
    out: Path = args.out
    out.mkdir(parents=True, exist_ok=True)

    if not FONT_PATH.is_file():
        raise SystemExit(f"找不到字体：{FONT_PATH}\n"
                         f"本脚本刻意不用微软雅黑/黑体/等线（专有授权），"
                         f"请确认 Noto Sans SC 已安装。")
    font, weight = load_font(FONT_SIZE)

    charset, per_source = collect_required_chars()
    n_new = len(charset) - len(LEGACY_CHARS)
    print(f"[1/4] 字符集：冻结 {len(LEGACY_CHARS)} 字 + 新增 {n_new} 字 = {len(charset)} 字形")
    print(f"      字体：{FONT_FAMILY} {weight} ({FONT_PATH.name})  {FONT_LICENSE}")
    print(f"      格子 {CELL_W}x{CELL_H}  字号 {FONT_SIZE}  阈值 {THRESHOLD}")
    print(f"      需求来源（按字符集大小）：")
    for desc, s in sorted(per_source.items(), key=lambda kv: -len(kv[1])):
        print(f"        {desc:<28} {len(s):>4} 字符")

    table = []
    for idx, ch in enumerate(charset):
        rows, metrics = render_glyph(font, ch)
        st = ink_stats(rows)
        table.append({"index": idx, "char": ch, "codepoint": f"U+{ord(ch):04X}",
                      "rows": rows, **st, **metrics})

    if args.art:
        for g in table:
            print(f"\nidx {g['index']:2d}  '{g['char']}'  {g['codepoint']}  "
                  f"墨点 {g['ink']:3d} ({g['ink_pct']:.1f}%)")
            print(ascii_art(g["rows"]))

    # ---- 索引冻结回归（必须在覆盖 .hex 之前跑）----
    # 两个独立的漂移风险：
    #   (a) 字符序列被重排 —— 由 LEGACY_CHARS 硬编码 + 断言保证；
    #   (b) 渲染参数被改动（字号/阈值/字重/锚点）导致同一字符画出不同点阵 ——
    #       只有拿磁盘上"上一版"的 .hex 逐位比对才能发现。重排和重绘都不报错，
    #       只会在屏幕上显示错字，所以这条回归是本次扩容唯一的防错闸。
    print(f"\n[回归] 索引 0..94 冻结校验")
    hex_path = out / "cjk16_bitmap.hex"
    seq_ok = (charset[:len(LEGACY_CHARS)] == LEGACY_CHARS)
    print(f"  [{'OK ' if seq_ok else 'BAD'}] 字符序列前 {len(LEGACY_CHARS)} 项与冻结常量逐字一致")
    legacy_check = {"available": False}
    if hex_path.is_file():
        prev = hex_path.read_text(encoding="ascii").split()
        n_prev = len(prev) // 16
        n_cmp = min(n_prev, len(LEGACY_CHARS))
        diff_rows = []
        for i in range(n_cmp):
            for r in range(16):
                old = int(prev[i * 16 + r], 16)
                if old != table[i]["rows"][r]:
                    diff_rows.append((i, r, old, table[i]["rows"][r]))
        legacy_check = {"available": True, "prev_glyphs": n_prev,
                        "compared": n_cmp, "diff_rows": len(diff_rows)}
        if diff_rows:
            i0, r0, o0, n0 = diff_rows[0]
            print(f"  [BAD] 冻结段重绘结果与上一版 .hex 不一致：{len(diff_rows)} 行不同，"
                  f"首个差异 索引{i0}({table[i0]['char']}) 第{r0}行 "
                  f"旧={o0:04x} 新={n0:04x}")
            print(f"        上一版 {n_prev} 字形；请检查字号/阈值/字重是否被改动")
        else:
            print(f"  [OK ] 冻结段 {n_cmp} 字形 x 16 行 = {n_cmp * 16} 行与上一版 .hex 逐位一致"
                  f"（上一版共 {n_prev} 字形）")
    else:
        diff_rows = []
        print(f"  [SKIP] 上一版 .hex 不存在，无法做重绘回归（首次生成）")
    ok = seq_ok and not diff_rows

    # ---- 导出 ----
    print(f"\n[2/4] 导出到 {out}")
    with hex_path.open("w", encoding="ascii", newline="\n") as fh:
        for g in table:
            for bits in g["rows"]:
                fh.write(f"{bits:04x}\n")
    print(f"  {hex_path.name:22s} {hex_path.stat().st_size:>8,} B  "
          f"（{len(table)} 字形 x 16 行 = {len(table) * 16} 行，可直接 $readmemh）")

    charset_path = out / "cjk16_charset.txt"
    lines = ["# 16x16 中文点阵字库 —— 索引 ↔ 字符对照",
             f"# 字体来源: {FONT_FAMILY} {weight} ({FONT_LICENSE})",
             f"# 格子: {CELL_W}x{CELL_H}  字号: {FONT_SIZE}  阈值: {THRESHOLD}",
             f"# 位序: 每行 16 bit, bit15 = 最左像素",
             f"# 行序: 索引 i 占 .hex 的第 i*16 .. i*16+15 行",
             "#",
             f"# 【索引冻结】索引 0..{len(LEGACY_CHARS) - 1} 共 {len(LEGACY_CHARS)} 个字形永久冻结，",
             "#   任何新增字符只能从后面追加，不得重排——RTL 以 index 硬引用字库，",
             "#   重排=屏幕静默显示错字（不报错、不变红，只是字不对）。",
             f"# 【扩容】本次共 {len(table)} 字形 = 冻结 {len(LEGACY_CHARS)} + 新增 {len(table) - len(LEGACY_CHARS)}。",
             f"#   新增部分按 Unicode 码位升序排列（便于查阅，且同批新增索引稳定）。",
             "#   需求来源（并集，非估算）：",
             ]
    for desc, s in sorted(per_source.items(), key=lambda kv: -len(kv[1])):
        lines.append(f"#     - {desc}: {len(s)} 字符")
    lines += ["#", "# index  char  codepoint  ink_pct"]
    for g in table:
        lines.append(f"{g['index']:5d}    {g['char']}     {g['codepoint']}   "
                     f"{g['ink_pct']:5.2f}%")
    charset_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"  {charset_path.name:22s} {charset_path.stat().st_size:>8,} B")

    json_path = out / "cjk16_bitmap.json"
    payload = {
        "schema": "cjk16-dotmatrix-v1",
        "cell": {"width": CELL_W, "height": CELL_H},
        "bit_order": "row-major, bit15 = leftmost pixel",
        "font": {"family": FONT_FAMILY, "file": FONT_PATH.name,
                 "size": FONT_SIZE, "weight": weight,
                 "license": FONT_LICENSE,
                 "attribution_doc": "docs/science_font_attribution.md"},
        "raster": {"threshold": THRESHOLD, "anchor": "mm"},
        "glyph_count": len(table),
        "source_phrases": OSD_PHRASES,
        "glyphs": [{"index": g["index"], "char": g["char"],
                    "codepoint": g["codepoint"],
                    "rows_hex": [f"{b:04x}" for b in g["rows"]],
                    "ink_pixels": g["ink"], "ink_pct": g["ink_pct"]}
                   for g in table],
    }
    json_path.write_text(json.dumps(payload, ensure_ascii=False, indent=1),
                         encoding="utf-8")
    print(f"  {json_path.name:22s} {json_path.stat().st_size:>8,} B")

    preview_path = out / "cjk16_preview.png"
    psize = emit_preview(table, preview_path)
    print(f"  {preview_path.name:22s} {preview_path.stat().st_size:>8,} B  "
          f"{psize[0]}x{psize[1]}")

    # Verilog case 表 ROM（captain 要求：工程惯例用 case 实现，TD 推断 ROM 更稳）
    v_path = out / "cjk16_font.v"
    vinfo = emit_verilog(table, v_path, weight)
    print(f"  {v_path.name:22s} {v_path.stat().st_size:>8,} B  "
          f"（{vinfo['glyphs']} 字形 x 16 行 = {vinfo['constants']} 条常量，"
          f"glyph 位宽 {vinfo['glyph_bits']} bit）")

    # ---- 自检 ----
    # 注意：不要把 ok 重置成 True —— 上面的索引冻结回归已经往 ok 里写过结果
    print(f"\n[3/4] 自检：")

    empty = [g for g in table if g["ink"] == 0]
    ok &= not empty
    print(f"  [{'OK ' if not empty else 'BAD'}] 无空字形"
          f"{'' if not empty else '，空字形：' + ' '.join(g['char'] for g in empty)}")

    # 墨点率区间：**汉字**在 Regular 字重下实测 8%~40%（「一」类字少、密集字多），
    # 全角标点（：；，。）笔画天然稀疏，下限放到 2%；上限 45% 用于捕捉
    # "字重过重导致糊连"——Bold 时密集字会到 50%+ 并出现笔画粘连。
    #
    # 但**不能用同一把尺量半角符号**：'-' ':' '%' '0'~'9' 这类字符在 16x16 里
    # 本来就只占几个像素（实测 '-' 1.56%、':' 1.56%），拿汉字下限去卡它们只会
    # 制造假警报。所以判据按字符类别分开：汉字/全角标点用 [2.0, 45.0]，
    # 半角符号只要求"非空"（真正的可读性靠 preview.png 目检）。
    # 注意：墨点率只是**粗筛**，不能替代目视——判断糊连要看 preview.png。
    lo, hi = 2.0, 45.0

    def _is_cjk_or_fullwidth(ch: str) -> bool:
        cp = ord(ch)
        return (0x4E00 <= cp <= 0x9FFF          # CJK 统一表意
                or 0x3000 <= cp <= 0x303F       # CJK 标点（、。「」）
                or 0xFF00 <= cp <= 0xFFEF       # 全角形式（：，！？％℃）
                or cp == 0x2103)                # ℃ 在 0x2103，不在全角区

    cjk_glyphs = [g for g in table if _is_cjk_or_fullwidth(g["char"])]
    half_glyphs = [g for g in table if not _is_cjk_or_fullwidth(g["char"])]
    odd = [g for g in cjk_glyphs if not (lo <= g["ink_pct"] <= hi)]
    odd_half = [g for g in half_glyphs if g["ink"] == 0]
    ok &= not odd and not odd_half
    odd_desc = "，异常：" + " ".join(f"{g['char']}({g['ink_pct']}%)" for g in odd)
    print(f"  [{'OK ' if not odd else 'BAD'}] 汉字/全角字形墨点率均在 {lo}%~{hi}%"
          f"（{len(cjk_glyphs)} 字形）{'' if not odd else odd_desc}")
    hp = sorted(g["ink_pct"] for g in half_glyphs)
    print(f"  [{'OK ' if not odd_half else 'BAD'}] 半角符号字形均非空"
          f"（{len(half_glyphs)} 字形，墨点率 {hp[0] if hp else 0}%~{hp[-1] if hp else 0}%，"
          f"天然偏低，不套汉字下限）")

    # 真正判"裁字"：墨迹本身大于 16x16 才算被裁。
    # 不能用"最外圈有墨点"当判据 —— 包围盒居中后，字形合法地铺满整格
    # （汉字本来就近满框），那样会把正常字形误报成切边。
    clipped = [g for g in table if g["clipped"]]
    ok &= not clipped
    clip_desc = "，裁字：" + " ".join(
        f"{g['char']}({g['ink_w']}x{g['ink_h']})" for g in clipped)
    print(f"  [{'OK ' if not clipped else 'BAD'}] 无裁字（墨迹均 <= {CELL_W}x{CELL_H}）"
          f"{'' if not clipped else clip_desc}")
    max_w = max(g["ink_w"] for g in table)
    max_h = max(g["ink_h"] for g in table)
    print(f"       最大墨迹 {max_w}x{max_h}（格子 {CELL_W}x{CELL_H}），"
          f"铺满整格是汉字正常现象")

    # 字形互不相同
    seen_map, dups = {}, []
    for g in table:
        key = tuple(g["rows"])
        if key in seen_map:
            dups.append((seen_map[key], g["char"]))
        else:
            seen_map[key] = g["char"]
    ok &= not dups
    print(f"  [{'OK ' if not dups else 'BAD'}] 字形互不相同（{len(seen_map)} 个唯一字形）"
          f"{'' if not dups else '，重复：' + str(dups)}")

    # 回读 .hex 重建位图，逐位比对（验证导出无损）
    hex_lines = hex_path.read_text(encoding="ascii").split()
    rebuilt = [[int(hex_lines[i * 16 + r], 16) for r in range(16)]
               for i in range(len(table))]
    lossless = all(rebuilt[i] == table[i]["rows"] for i in range(len(table)))
    ok &= lossless and len(hex_lines) == len(table) * 16
    print(f"  [{'OK ' if lossless else 'BAD'}] .hex 回读重建与内存位图逐位一致"
          f"（{len(hex_lines)} 行 = {len(table)}x16）")

    # preview.png 能被 Pillow 重新打开
    with Image.open(preview_path) as im:
        pv_ok = im.size == psize and im.mode == "RGB"
    ok &= pv_ok
    print(f"  [{'OK ' if pv_ok else 'BAD'}] preview.png 可被 Pillow 重新打开"
          f"（{psize[0]}x{psize[1]} RGB）")

    # json 可被重新解析
    reloaded = json.loads(json_path.read_text(encoding="utf-8"))
    js_ok = (reloaded["glyph_count"] == len(table)
             and len(reloaded["glyphs"]) == len(table))
    ok &= js_ok
    print(f"  [{'OK ' if js_ok else 'BAD'}] json 可重新解析且字形数一致"
          f"（{reloaded['glyph_count']}）")

    # ---- 覆盖率：对每个真实文本来源逐一核对"有没有缺字" ----
    # 这是本次扩容的核心验收项。缺字不会让脚本失败，只会让屏幕出现方块，
    # 所以必须逐来源打印，缺一个字就判 BAD。
    have = {g["char"] for g in table}
    print(f"  覆盖率（逐来源）：")
    cov_ok = True
    for desc, s in sorted(per_source.items(), key=lambda kv: -len(kv[1])):
        miss = sorted(s - have)
        cov_ok &= not miss
        print(f"    [{'OK ' if not miss else 'BAD'}] {desc:<28} "
              f"{len(s):>4} 字符  缺 {len(miss):>3}"
              f"{'' if not miss else '  缺字：' + ''.join(miss)}")
    ok &= cov_ok
    hanzi = [c for c in have if "\u4e00" <= c <= "\u9fff"]
    print(f"       全集 {len(have)} 字符（汉字 {len(hanzi)}、非汉字 {len(have) - len(hanzi)}），"
          f"缺字合计 {sum(len(s - have) for s in per_source.values())}")

    # ---- .v / .hex / 字形数 三者字节级自洽 ----
    # 三个文件描述同一份数据，任何一个落后于另外两个都会导致"上板字形不全"，
    # 而这类不一致在单看某个文件时完全看不出来。
    # 统计 payload 常量必须用行首锚定的正则：文件里还有 default 分支的
    # `16'h0000` 和【六】注释里的 `16'h0000`，直接 count("16'h") 会多算 2 条。
    v_txt = v_path.read_text(encoding="utf-8")
    v_payload = re.findall(
        r"^\s+\d+'d\d+: pixels = 16'h[0-9A-F]{4};$", v_txt, re.MULTILINE)
    v_glyph_decl = re.search(r"input\s+wire\s+\[(\d+):0\]\s+glyph", v_txt)
    v_case = re.search(r"case \(\{glyph, row\}\)", v_txt)
    v_default = re.search(r"default: pixels = 16'h0000;", v_txt)
    v_ok = (len(v_payload) == len(table) * 16
            and v_glyph_decl is not None
            and int(v_glyph_decl.group(1)) == vinfo["glyph_bits"] - 1
            and v_case is not None and v_default is not None
            and len(hex_lines) == len(table) * 16
            and vinfo["glyphs"] == len(table))
    ok &= v_ok
    print(f"  [{'OK ' if v_ok else 'BAD'}] .v/.hex/字形数自洽"
          f"（.v 端口 glyph[{(int(v_glyph_decl.group(1)) + 1) if v_glyph_decl else '?'}]"
          f"位宽 {vinfo['glyph_bits']} bit、payload {len(v_payload)} 条 = {len(table)}x16、"
          f"case/default 齐备 {bool(v_case) and bool(v_default)}；"
          f".hex {len(hex_lines)} 行；json {reloaded['glyph_count']} 字形）")
    if v_glyph_decl and int(v_glyph_decl.group(1)) + 1 < (len(table) - 1).bit_length():
        print(f"  [BAD] glyph 端口位宽 {int(v_glyph_decl.group(1)) + 1} bit 不足以索引"
              f" 0..{len(table) - 1}")
        ok = False

    print(f"\n[4/4] 产出清单")
    for p in (hex_path, charset_path, json_path, preview_path):
        print(f"  {p.name:22s} {p.stat().st_size:>8,} B  sha256={sha256_of(p)[:16]}…")

    print(f"\n[自检] {'全部通过' if ok else '存在失败项'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
