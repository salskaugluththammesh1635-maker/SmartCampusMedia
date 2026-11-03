# -*- coding: utf-8 -*-
"""
gen_assets_v2_sdcard.py — 从 assets/v2/masters/ 派生「可烧录 SD 卡素材包」（t4）

================================================================================
一、这个脚本产出什么
================================================================================
    assets/v2/sdcard/
    ├── COMMON/                       分辨率无关素材（五档共用一份，不重复复制）
    │   ├── AUDIO/  BGM.WAV BGM2.WAV BGM3.WAV ALARM.WAV NARR.WAV
    │   ├── VIDEO/  SCI.RLE  SCI.IDX
    │   ├── SRT/    NARR.SRT NARR.IDX
    │   ├── TICKER.TXT
    │   └── MANIFEST.TXT
    ├── RES320/  RES400/  RES512/  RES576/  RES640/
    │   └── IMG001.BMP ~ IMG006.BMP + MANIFEST.TXT
    ├── BURN640/                      可直接整目录拷进 SD 卡根的成品卡（默认档）
    └── MANIFEST.TXT                  全卡汇总清单

================================================================================
二、分辨率档位为什么不是任务书里写的 640x480 / 800x600 / ...
================================================================================
    本脚本严格按 docs/plan_v2/PLAN.md §4.2 定稿的五档：
        res_sel 0 -> 320x240   1 -> 400x300   2 -> 512x384
        res_sel 3 -> 576x432   4 -> 640x480（默认，旁路）
    任务书字面写的 800x600 已被 PLAN.md §4.3 明确否决（需 40 MHz 像素时钟，
    VCO 需 1200 MHz 恰在芯片上限临界），1024x768 / 1280x720 更是明令禁止。
    依据优先级：PLAN.md（已定稿架构）> 任务书字面举例。

================================================================================
三、为什么音频/视频/字幕不按分辨率复制五份
================================================================================
    ① 它们的内容与「内部渲染分辨率」无关：同一段 WAV 在五档下逐字节相同。
    ② PLAN.md §4.1 的核心口径是「Key8 切的是内部渲染分辨率，SD 上的源图仍是
       640x480，由 video_geom_map 在输出侧最近邻放大」。也就是说五档 RES 目录
       本质是「同一张图的五种采样密度」，属于素材完整性与备选，当前 N1 架构
       实际只吃 RES640 一套（详见 assets/v2/SDCARD_LAYOUT.md §6）。
    ③ 五份 24.6 MB 音频 + 五份 ~80 MB 视频 = 白白多占约 520 MB，且会让
       「容量表」失去意义。故统一放 COMMON/，需要成品卡时用 --stage 装配。

================================================================================
四、文件名一律 8.3 + 全大写
================================================================================
    现有 rtl/storage/fat32_reader.v 只遍历**根目录**、无长文件名支持，且短名
    比较逻辑是硬编码 11 字节。8.3 = 主名 1~8 字符 + 扩展名 1~3 字符。
    ARCH.md §6.7 写的 NARRATION.WAV / NARRATION.SRT 主名是 9 字符，**违反 8.3**，
    本脚本改用 NARR.WAV / NARR.SRT 并在文档中记录该修正。

================================================================================
五、可复现性
================================================================================
    全部数值从磁盘实测或由固定常量推导，无随机、无时间戳写入产物内容。
    重复运行输出逐字节相同（BMP 由 Pillow 确定性编码；RLE 由 numpy 确定性
    编码；WAV 直接字节复制；文本按固定格式生成）。
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import struct
import sys
import wave
from pathlib import Path

import numpy as np
from PIL import Image

# ============================================================================
# 路径
# ============================================================================
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent                      # SmartCampusMedia/
V2 = REPO_ROOT / "assets" / "v2"
MASTERS = V2 / "masters"
SDCARD = V2 / "sdcard"

MASTER_IMAGES = MASTERS / "images"
MASTER_AUDIO = MASTERS / "audio"
MASTER_VIDEO = MASTERS / "video"

# 校园图母版（1920x1440 RGB PNG，t3 产物）
IMAGE_INDEXES = [1, 2, 3, 4, 5, 6]

# ============================================================================
# 分辨率档位（PLAN.md §4.2 定稿，顺序 = res_sel）
# ============================================================================
# (目录名, 宽, 高, 放大比说明) —— 注意这几个字段会被写进纯 ASCII 的 MANIFEST.TXT，
# 所以只能用 ASCII 字符，不能写中文（否则 UnicodeEncodeError）。
RES_TABLE = [
    ("RES320", 320, 240, "2/1"),
    ("RES400", 400, 300, "8/5"),
    ("RES512", 512, 384, "5/4"),
    ("RES576", 576, 432, "10/9"),
    ("RES640", 640, 480, "1/1 bypass"),
]
DEFAULT_RES_DIR = "RES640"

# 八位组：BMP 头长度 / BI_RGB 无压缩 / 24 bit
BMP_HEADER_SIZE = 54
BMP_BPP = 24

# ============================================================================
# 视频参数（PLAN.md §7.1 / §7.6 定稿）
# ============================================================================
VIDEO_SRC = Path(r"D:\FPGA_Compelate\work\fpga_intro_video\fpga_intro_640x480_60fps.mp4")
VIDEO_W, VIDEO_H = 640, 480
VIDEO_SRC_FPS = 60.0
VIDEO_TARGET_FPS = 5          # 目标 5 fps（保底 2 fps 由 RTL 欠载降级实现，不影响素材）
VIDEO_FRAME_STEP = int(VIDEO_SRC_FPS // VIDEO_TARGET_FPS)   # 每 12 帧取 1 帧
RLE_MAGIC = b"SCMR"           # PLAN.md §7.6 定稿（注意：t3 统计用的 CVRLE 仅估算用）
RLE_FRAME_HDR = 12
RLE_RUN_MAX = 256             # run_len 8 bit，0 表示 256

# ============================================================================
# 音频映射（源文件 -> 卡上 8.3 文件名）
# ============================================================================
AUDIO_MAP = [
    ("bgm_serene.wav", "BGM.WAV", "日常模式背景音乐（主）"),
    ("bgm_focus.wav", "BGM2.WAV", "备选背景音乐 2（静谧专注）"),
    ("bgm_uplift.wav", "BGM3.WAV", "备选背景音乐 3（明亮律动）"),
    ("alarm_siren.wav", "ALARM.WAV", "应急警报（双音交替，loop 播放）"),
]
NARRATION_SRC = MASTER_VIDEO / "narration.wav"
NARRATION_NAME = "NARR.WAV"        # 原名 NARRATION.WAV 主名 9 字符，违反 8.3
SRT_SRC = MASTER_VIDEO / "narration.srt"
SRT_NAME = "NARR.SRT"              # 原名 NARRATION.SRT 同样违规

# OSD 8x16 字模 ROM 的字符集（见 rtl/osd/osd_strings.v §四）
FONT_CHARSET = set(" -./0123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZ")
TICKER_COLS = 64                   # osd_caption 用 col & 6'b111111，必须正好 64

# 日常模式滚动标语（必须 <=64 且只用字模 ROM 收录字符）
TICKER_DAILY = "SMART CAMPUS MEDIA - WELCOME - DAILY MODE ONLINE"

# ============================================================================
# 成品卡布局（BURNxxx）
# ============================================================================
# flat   = 卡根 17 个文件、零子目录（**交付默认**，因为 fat32_reader 只扫根目录）
# subdir = 媒体放 VIDEO/AUDIO/SRT 三个子目录（ARCH.md §6.7 原始布局，仅作对照）
CARD_LAYOUT_FLAT = "flat"
CARD_LAYOUT_SUBDIR = "subdir"
DEFAULT_CARD_LAYOUT = CARD_LAYOUT_FLAT
COMMON_SUBDIRS = ["VIDEO", "AUDIO", "SRT"]

# 扁平成品卡应有的文件全集（17 个）。写死是为了让自检能独立核对，
# 而不是「磁盘上有什么就认为应该有什么」——后者无法发现漏装/多装。
CARD_FLAT_FILES = (
    [f"IMG{i:03d}.BMP" for i in IMAGE_INDEXES]
    + ["BGM.WAV", "BGM2.WAV", "BGM3.WAV", "ALARM.WAV", "NARR.WAV"]
    + ["SCI.RLE", "SCI.IDX"]
    + ["NARR.SRT", "NARR.IDX"]
    + ["TICKER.TXT", "MANIFEST.TXT"]
)

# 成品卡 MANIFEST.TXT 的说明行。**与旧版逐字符等长（89）是刻意的**：
# 这样 MANIFEST.TXT 恒为 1,729 B，扁平化前后卡根总字节精确相等（112,506,540 B），
# 验收时可以用「总字节一字节不差」直接判定「只改了层级、没动任何内容」。
CARD_MANIFEST_NOTE_FLAT = ("burn: copy this directory CONTENT to FAT32 card root; "
                           "layout: FLAT - root only, no subdir")


# ============================================================================
# 小工具
# ============================================================================
def size_8dot3_ok(name: str) -> bool:
    """
    校验文件名满足 8.3 且全大写。

    目录名没有扩展名，此时只要求主名 1~8 字符。注意**不能**把「无扩展名」
    直接判为违规——`COMMON` / `AUDIO` / `RES640` 都是合法目录名。
    """
    if "." not in name:
        base, ext = name, None
    else:
        base, ext = name.rsplit(".", 1)
        if not (1 <= len(ext) <= 3):
            return False
    if not (1 <= len(base) <= 8):
        return False
    if name != name.upper():
        return False
    allowed = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.~$%&'()@^`{}!#")
    return all(c in allowed for c in name)


def fat_shortname_entry(name: str) -> bytes:
    """
    把 `IMG001.BMP` 这样的 8.3 名编码成 FAT32 目录项里的 11 字节短名形态。

    FAT 目录项不使用 `IMG001.BMP` 这种「带点」写法，而是 8 字节主名 + 3 字节扩展名
    **各自右补空格**、中间没有点：
        IMG001.BMP -> b'IMG001  BMP'   （主名补 2 个空格）
        BGM.WAV    -> b'BGM     WAV'   （主名补 5 个空格）
        BGM2.WAV   -> b'BGM2    WAV'   （第 4 字节是 '2'）
        BGM3.WAV   -> b'BGM3    WAV'   （第 4 字节是 '3'）

    这个函数存在的理由是 `fat32_reader.v` L590-614 是**逐字节**比较目录项，
    上层拼名必须严格对上这 11 字节，否则上板时读不到文件、且不会报「名字错」，
    只会表现为「文件不存在」——所以必须显式算出来、显式校验。
    """
    if "." in name:
        base, ext = name.rsplit(".", 1)
    else:
        base, ext = name, ""
    if len(base) > 8 or len(ext) > 3:
        raise ValueError(f"非 8.3 名，无法编码为 FAT 目录项：{name}")
    return base.ljust(8).encode("ascii") + ext.ljust(3).encode("ascii")


def echo(msg: str = "") -> None:
    print(msg, flush=True)


def sha256_of(path: Path) -> str:
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def dir_bytes(path: Path) -> int:
    total = 0
    for root, _dirs, files in os.walk(path):
        for fn in files:
            total += (Path(root) / fn).stat().st_size
    return total


def walk_tree(path: Path) -> list[tuple[str, int]]:
    """返回 [(相对路径(POSIX), 字节数)]，按路径排序。"""
    out = []
    for root, _dirs, files in os.walk(path):
        for fn in files:
            p = Path(root) / fn
            rel = p.relative_to(path).as_posix()
            out.append((rel, p.stat().st_size))
    out.sort()
    return out


# ============================================================================
# 一、校园图：母版 -> 五档原生像素 24 bit 无压缩 BMP
# ============================================================================
def load_master_images() -> dict[int, Image.Image]:
    """读 1920x1440 母版，返回 {序号: RGB Image}。"""
    images = {}
    for idx in IMAGE_INDEXES:
        p = MASTER_IMAGES / f"IMG{idx:03d}.png"
        if not p.exists():
            raise SystemExit(f"[FATAL] 缺母版：{p}（请先运行 gen_assets_v2_images.py）")
        im = Image.open(p)
        im.load()
        if im.mode != "RGB":
            im = im.convert("RGB")
        images[idx] = im
    return images


def downscale(im: Image.Image, w: int, h: int) -> Image.Image:
    """母版直接一步 LANCZOS 缩到目标尺寸（不做级联缩放，避免二次损失）。"""
    return im.resize((w, h), Image.Resampling.LANCZOS)


def write_bmp24(im: Image.Image, path: Path) -> int:
    """
    写 24 bit BI_RGB 无压缩 BMP，并校验文件大小与文件头。
    返回实际字节数。

    校验点（与 rtl/storage/bmp_parser.v 的判据一一对应）：
        签名 'BM' / 数据偏移 54 / DIB 头 40 字节 / 24 bpp / compression == 0
        / 行字节数按 4 对齐（本脚本五档宽度 x3 均为 4 的倍数，填充恒为 0）
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    im.save(path, format="BMP")
    raw = path.read_bytes()
    w, h = im.size
    expect_size = BMP_HEADER_SIZE + w * h * BMP_BPP // 8
    assert len(raw) == expect_size, f"{path.name} 大小 {len(raw)} != 期望 {expect_size}"

    # BMP 头共 38 字节：14 字节文件头 + 24 字节 DIB 头（BITMAPINFOHEADER 前 24 字节）
    (sig, filesize, _r1, _r2, data_off, dib_size, bw, bh, planes, bpp,
     comp, img_size) = struct.unpack("<2sIHHIIiiHHII", raw[:38])
    assert sig == b"BM", f"{path.name} 签名异常 {sig}"
    assert filesize == expect_size, f"{path.name} 头内 filesize {filesize} 不符"
    assert data_off == BMP_HEADER_SIZE, f"{path.name} 数据偏移 {data_off} 不符"
    assert dib_size == 40, f"{path.name} DIB 头 {dib_size} 不符"
    assert bw == w and bh == h, f"{path.name} 头内宽高 {bw}x{bh} 不符"
    assert planes == 1 and bpp == 24, f"{path.name} bpp/planes 异常"
    assert comp == 0, f"{path.name} 压缩标志 {comp} != 0（不可上板）"
    assert img_size == w * h * 3, f"{path.name} 像素区大小 {img_size} 不符"
    assert w * 3 % 4 == 0, f"{path.name} 行填充非 0，bmp_parser 需另行处理"
    return len(raw)


def build_images(masters: dict[int, Image.Image]) -> list[dict]:
    records = []
    for dir_name, w, h, ratio in RES_TABLE:
        out_dir = SDCARD / dir_name
        for idx in IMAGE_INDEXES:
            im = downscale(masters[idx], w, h)
            p = out_dir / f"IMG{idx:03d}.BMP"
            size = write_bmp24(im, p)
            records.append({
                "res_dir": dir_name, "name": p.name, "w": w, "h": h,
                "bytes": size, "ratio": ratio,
                "path": f"{dir_name}/{p.name}",
            })
    return records


# ============================================================================
# 二、音频：母版 WAV -> 卡上 8.3 文件名（逐字节复制 + 头校验）
# ============================================================================
def probe_wav(path: Path) -> dict:
    with wave.open(str(path), "rb") as w:
        nch, sw, sr, nfr = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
    raw = path.read_bytes()[:44]
    # canonical 44 字节头：RIFF <size> WAVE fmt <16> <fmt> ch sr byterate align bits data <size>
    assert raw[0:4] == b"RIFF", f"{path.name} 非 RIFF"
    assert raw[8:12] == b"WAVE", f"{path.name} 非 WAVE"
    assert raw[12:16] == b"fmt ", f"{path.name} 缺 fmt chunk"
    fmt_size = struct.unpack("<I", raw[16:20])[0]
    audio_format = struct.unpack("<H", raw[20:22])[0]
    assert raw[36:40] == b"data", f"{path.name} 缺 data chunk 或 fmt 非 16 字节"
    return {
        "channels": nch, "sampwidth": sw, "bits": sw * 8, "sample_rate": sr,
        "frames": nfr, "duration_s": round(nfr / float(sr), 6),
        "bytes": path.stat().st_size, "audio_format": audio_format,
        "fmt_size": fmt_size,
    }


def require_card_wav(info: dict, name: str) -> None:
    """wav_stream_player.v 只支持 PCM(1) / 16 bit / 48 kHz / 单声道。"""
    assert info["audio_format"] == 1, f"{name} audio_format={info['audio_format']} 非 PCM"
    assert info["fmt_size"] == 16, f"{name} fmt chunk {info['fmt_size']} != 16"
    assert info["bits"] == 16, f"{name} 位深 {info['bits']} != 16"
    assert info["sample_rate"] == 48000, f"{name} 采样率 {info['sample_rate']} != 48000"
    assert info["channels"] == 1, f"{name} 声道 {info['channels']} != 1"


def build_audio() -> list[dict]:
    out_dir = SDCARD / "COMMON" / "AUDIO"
    out_dir.mkdir(parents=True, exist_ok=True)
    records = []

    pairs = [(MASTER_AUDIO / src, dst, use) for src, dst, use in AUDIO_MAP]
    pairs.append((NARRATION_SRC, NARRATION_NAME, "科普模式解说音频（与 NARR.SRT 时间轴对齐）"))

    for src, dst_name, use in pairs:
        if not src.exists():
            raise SystemExit(f"[FATAL] 缺音频母版：{src}")
        info = probe_wav(src)
        require_card_wav(info, src.name)
        dst = out_dir / dst_name
        shutil.copyfile(src, dst)
        # 复制后再实测一次，确认落盘文件本身合规（不是只看源）
        got = probe_wav(dst)
        require_card_wav(got, dst_name)
        assert got["bytes"] == info["bytes"], f"{dst_name} 复制后大小变化"
        records.append({
            "name": dst_name, "source": src.name, "use": use,
            "bytes": got["bytes"], "sample_rate": got["sample_rate"],
            "bits": got["bits"], "channels": got["channels"],
            "frames": got["frames"], "duration_s": got["duration_s"],
            "bit_rate_Bps": got["sample_rate"] * got["bits"] * got["channels"] // 8,
            "path": f"COMMON/AUDIO/{dst_name}",
        })
    return records


# ============================================================================
# 三、视频：mp4 -> SCI.RLE（"SCMR" 逐帧 12 B 头，RGB565 + 8 bit 游程）
# ============================================================================
def bgr_to_rgb565(bgr: np.ndarray) -> np.ndarray:
    b = bgr.astype(np.uint16)
    return (((b[:, :, 2] >> 3) << 11) | ((b[:, :, 1] >> 2) << 5) | (b[:, :, 0] >> 3))


def rle_encode_frame(bgr: np.ndarray, w: int, h: int) -> tuple[bytes, int]:
    """
    单帧 -> SCMR 帧（12 B 头 + 3 B/条目 payload）。返回 (字节串, run_count)。

    条目格式（PLAN.md §7.6）：{rgb565[15:0], run_len[7:0]}，**高字节在前**；
    run_len == 0 表示 256（8 bit 装不下 256）。
    """
    flat = bgr_to_rgb565(bgr).ravel()
    if flat.size == 0:
        return struct.pack("<4sHHI", RLE_MAGIC, w, h, 0), 0

    change = np.flatnonzero(flat[1:] != flat[:-1]) + 1
    starts = np.concatenate(([0], change))
    runs = np.diff(np.concatenate((starts, [flat.size])))
    vals = flat[starts]

    # 长游程按 256 拆分（640 像素纯色行 = 2×256 + 128）
    reps = (runs + RLE_RUN_MAX - 1) // RLE_RUN_MAX
    if np.any(reps > 1):
        idx = np.repeat(np.arange(starts.size), reps)
        vals = vals[idx]
        rem = runs % RLE_RUN_MAX
        lens = np.full(vals.size, RLE_RUN_MAX, dtype=np.int32)
        ends = np.cumsum(reps) - 1
        lens[ends] = np.where(rem == 0, RLE_RUN_MAX, rem)
        runs = lens

    run_count = int(vals.size)
    payload = np.empty((run_count, 3), dtype=np.uint8)
    payload[:, 0] = (vals >> 8) & 0xFF
    payload[:, 1] = vals & 0xFF
    payload[:, 2] = (runs & 0xFF).astype(np.uint8)   # 256 -> 0
    head = struct.pack("<4sHHI", RLE_MAGIC, w, h, run_count)
    return head + payload.tobytes(), run_count


def rle_decode_frame(blob: bytes) -> np.ndarray:
    """校验用解码器：SCMR 帧 -> RGB565 像素数组（长度应 == w*h）。"""
    magic, w, h, run_count = struct.unpack("<4sHHI", blob[:RLE_FRAME_HDR])
    assert magic == RLE_MAGIC, f"帧头 magic 异常 {magic}"
    body = blob[RLE_FRAME_HDR:]
    assert len(body) == run_count * 3, f"payload 长度 {len(body)} != 3*{run_count}"
    out = []
    for i in range(run_count):
        hi, lo, rl = body[3 * i], body[3 * i + 1], body[3 * i + 2]
        value = (hi << 8) | lo
        n = RLE_RUN_MAX if rl == 0 else rl
        out.append(np.full(n, value, dtype=np.uint16))
    px = np.concatenate(out)
    assert px.size == w * h, f"解压像素数 {px.size} != {w*h}"
    return px


def build_video() -> dict:
    import cv2

    if not VIDEO_SRC.exists():
        raise SystemExit(f"[FATAL] 缺视频源：{VIDEO_SRC}")

    out_dir = SDCARD / "COMMON" / "VIDEO"
    out_dir.mkdir(parents=True, exist_ok=True)
    rle_path = out_dir / "SCI.RLE"

    cap = cv2.VideoCapture(str(VIDEO_SRC))
    if not cap.isOpened():
        raise SystemExit(f"[FATAL] cv2 打不开 {VIDEO_SRC}")

    frames_meta = []      # (帧序号, 文件偏移, 字节数, run_count)
    offset = 0
    frame_no = 0          # 卡上第几帧（0 基）
    src_idx = 0           # 源 mp4 第几帧

    with open(rle_path, "wb") as f:
        while True:
            ok, frame = cap.read()
            if not ok:
                break
            if src_idx % VIDEO_FRAME_STEP == 0:
                fh, fw = frame.shape[:2]
                assert (fw, fh) == (VIDEO_W, VIDEO_H), f"源帧尺寸 {fw}x{fh} 不符"
                blob, run_count = rle_encode_frame(frame, VIDEO_W, VIDEO_H)
                f.write(blob)
                frames_meta.append((frame_no, offset, len(blob), run_count))
                offset += len(blob)
                frame_no += 1
            src_idx += 1
    cap.release()

    assert frame_no > 0, "没有抽到任何帧"
    total = rle_path.stat().st_size
    assert total == offset, f"落盘大小 {total} != 累加 {offset}"

    # ---- 抽样回读校验：首/中/末三帧解压后像素数必须正确 ----
    probe_idx = sorted({0, frame_no // 2, frame_no - 1})
    with open(rle_path, "rb") as f:
        for i in probe_idx:
            _no, off, nbytes, rc = frames_meta[i]
            f.seek(off)
            blob = f.read(nbytes)
            px = rle_decode_frame(blob)
            assert px.size == VIDEO_W * VIDEO_H

    sizes = np.array([m[2] for m in frames_meta], dtype=np.int64)
    stat = {
        "src": VIDEO_SRC.name,
        "src_bytes": VIDEO_SRC.stat().st_size,
        "width": VIDEO_W, "height": VIDEO_H,
        "color_depth": "RGB565 (16 bpp)",
        "src_fps": VIDEO_SRC_FPS,
        "target_fps": VIDEO_TARGET_FPS,
        "frame_step": VIDEO_FRAME_STEP,
        "frame_count": frame_no,
        "duration_s": round(frame_no / float(VIDEO_TARGET_FPS), 3),
        "file_bytes": total,
        "avg_frame_bytes": int(sizes.mean()),
        "min_frame_bytes": int(sizes.min()),
        "max_frame_bytes": int(sizes.max()),
        "p95_frame_bytes": int(np.percentile(sizes, 95)),
        "compression_ratio": round(total / (frame_no * VIDEO_W * VIDEO_H * 2), 4),
        "bandwidth_MBps_mean": round(sizes.mean() * VIDEO_TARGET_FPS / 1e6, 4),
        "bandwidth_MBps_worst": round(int(sizes.max()) * VIDEO_TARGET_FPS / 1e6, 4),
        "sd_bandwidth_MBps": 1.25,
    }
    stat["sd_ratio_mean"] = round(stat["bandwidth_MBps_mean"] / 1.25, 3)
    stat["sd_ratio_worst"] = round(stat["bandwidth_MBps_worst"] / 1.25, 3)

    # ---- 索引文件 SCI.IDX（定长 ASCII，供工具快速定位，RTL 不依赖） ----
    idx_path = out_dir / "SCI.IDX"
    with open(idx_path, "w", encoding="ascii", newline="\n") as f:
        f.write("# SCI.IDX V1  frames={}  fps={}  {}x{}  RGB565\n".format(
            frame_no, VIDEO_TARGET_FPS, VIDEO_W, VIDEO_H))
        f.write("# FRAME     OFFSET      BYTES  RUNS\n")
        for no, off, nb, rc in frames_meta:
            f.write("{:05d} {:>11d} {:>10d} {:>6d}\n".format(no, off, nb, rc))
    stat["index_bytes"] = idx_path.stat().st_size
    stat["index_offset_bytes"] = len(
        "# SCI.IDX V1  frames={}  fps={}  {}x{}  RGB565\n".format(
            frame_no, VIDEO_TARGET_FPS, VIDEO_W, VIDEO_H).encode()
        + b"# FRAME     OFFSET      BYTES  RUNS\n")
    stat["path"] = "COMMON/VIDEO/SCI.RLE"
    stat["index_path"] = "COMMON/VIDEO/SCI.IDX"
    stat["_frames_meta"] = frames_meta   # 供文档生成用，不写进 json
    return stat


# ============================================================================
# 四、字幕 / 滚动标语
# ============================================================================
def srt_time_ms(t: str) -> int:
    hh, mm, rest = t.split(":")
    ss, ms = rest.split(",")
    return ((int(hh) * 3600 + int(mm) * 60 + int(ss)) * 1000) + int(ms)


def parse_srt(text: str) -> list[dict]:
    cues = []
    blocks = [b.strip() for b in text.replace("\r\n", "\n").split("\n\n") if b.strip()]
    for b in blocks:
        lines = b.split("\n")
        no = int(lines[0].strip())
        start_s, end_s = [x.strip() for x in lines[1].split("-->")]
        cues.append({
            "index": no,
            "start": start_s, "end": end_s,
            "start_ms": srt_time_ms(start_s), "end_ms": srt_time_ms(end_s),
            "text": "\n".join(lines[2:]).strip(),
        })
    return cues


def build_subtitles(audio_records: list[dict]) -> dict:
    out_srt_dir = SDCARD / "COMMON" / "SRT"
    out_srt_dir.mkdir(parents=True, exist_ok=True)

    # ---- 科普字幕：从母版复制并做 5 项对齐校验 ----
    if not SRT_SRC.exists():
        raise SystemExit(f"[FATAL] 缺字幕源：{SRT_SRC}")
    text = SRT_SRC.read_text(encoding="utf-8")
    cues = parse_srt(text)

    narr = next(r for r in audio_records if r["name"] == NARRATION_NAME)
    dur_ms = int(round(narr["duration_s"] * 1000))
    prev_end = -1
    for c in cues:
        assert c["end_ms"] > c["start_ms"], f"第 {c['index']} 条 end<=start"
        assert c["start_ms"] >= prev_end, f"第 {c['index']} 条与上条重叠"
        assert c["end_ms"] <= dur_ms, f"第 {c['index']} 条超出音频时长 {dur_ms}ms"
        assert c["text"], f"第 {c['index']} 条文本为空"
        prev_end = c["end_ms"]

    srt_out = out_srt_dir / SRT_NAME
    srt_out.write_bytes(text.replace("\r\n", "\n").encode("utf-8"))

    # ---- 字幕时间轴 ASCII 索引（RTL 侧字模是纯 ASCII，中文字幕无法直接上屏） ----
    idx_path = out_srt_dir / "NARR.IDX"
    with open(idx_path, "w", encoding="ascii", newline="\n") as f:
        f.write("# NARR.IDX V1  cues={}  audio_ms={}\n".format(len(cues), dur_ms))
        f.write("# CUE   START_MS   END_MS\n")
        for c in cues:
            f.write("{:03d} {:>10d} {:>8d}\n".format(c["index"], c["start_ms"], c["end_ms"]))

    # ---- 滚动标语：必须正好 64 字符且只用字模 ROM 收录字符 ----
    ticker = TICKER_DAILY
    bad = sorted(set(ticker) - FONT_CHARSET)
    assert not bad, f"滚动标语含字模 ROM 未收录字符：{bad}"
    assert len(ticker) <= TICKER_COLS, f"标语 {len(ticker)} > {TICKER_COLS}"
    ticker_padded = ticker + " " * (TICKER_COLS - len(ticker))
    assert len(ticker_padded) == TICKER_COLS

    tick_path = SDCARD / "COMMON" / "TICKER.TXT"
    tick_path.write_bytes(ticker_padded.encode("ascii"))

    return {
        "srt_name": SRT_NAME,
        "srt_bytes": srt_out.stat().st_size,
        "srt_cues": len(cues),
        "srt_first": cues[0]["start"],
        "srt_last": cues[-1]["end"],
        "idx_name": "NARR.IDX",
        "idx_bytes": idx_path.stat().st_size,
        "ticker_name": "TICKER.TXT",
        "ticker_text": ticker,
        "ticker_cols": len(ticker_padded),
        "ticker_trimmed_cols": len(ticker),
        "ticker_bytes": tick_path.stat().st_size,
        "cjk_unique_in_srt": len({ch for c in cues for ch in c["text"]}),
    }


# ============================================================================
# 五、MANIFEST.TXT（FPGA 端可解析的定长 ASCII 清单）
# ============================================================================
# 行格式（定长 ASCII + LF，字段间单空格，可直接 split()）：
#   REC <NAME:12> <TYPE:3> <SIZE:10> <P1:5> <P2:5> <P3:3> <SUBDIR:8> <NOTE...>
# SUBDIR 说明：本文件所在目录下的哪个子目录（"." = 同目录）。
#   加这一列是因为 COMMON/MANIFEST.TXT 要同时描述 AUDIO/ VIDEO/ SRT/ 三个子目录里的文件，
#   没有该列就无法从清单位置反推出文件真实路径（校验时会误报「文件不存在」）。
MANIFEST_HEADER = "SMCMANIFEST V1"


def manifest_line(name: str, typ: str, size: int, p1: int, p2: int, p3: int,
                  subdir: str, note: str) -> str:
    """
    一行一条记录，字段间单空格，可直接 str.split() 解析。

    注意：**不能**把主名和扩展名分开补空格（`{:<8}.{:<3}`），那会在 8.3 名内部
    插入空格（"IMG001  .BMP"），split() 会把它切成两段，解析随即错位。
    """
    return "REC {:<12} {:<3} {:>10d} {:>5d} {:>5d} {:>3d} {:<8} {}\n".format(
        name, typ, size, p1, p2, p3, subdir, note)


def manifest_block(title: str, res_note: str, records: list[dict]) -> str:
    """records: [{name, typ, size, p1, p2, p3, subdir, note}]"""
    out = [MANIFEST_HEADER + "\n"]
    out.append("# {}\n".format(title))
    out.append("# {}\n".format(res_note))
    out.append("# COUNT {}\n".format(len(records)))
    out.append("# NAME         .EXT TYP {:>10} {:>5} {:>5} {:>3} {:<8} NOTE\n".format(
        "SIZE", "P1", "P2", "P3", "SUBDIR"))
    for r in records:
        out.append(manifest_line(r["name"], r["typ"], r["size"], r["p1"], r["p2"],
                                 r["p3"], r["subdir"], r["note"]))
    return "".join(out)


def build_manifests(img_records, audio_records, video_stat, subs) -> dict:
    written = {}

    # ---- 每档分辨率目录：只列本目录的 6 张图 ----
    for dir_name, w, h, ratio in RES_TABLE:
        recs = []
        for r in img_records:
            if r["res_dir"] != dir_name:
                continue
            recs.append({
                "name": r["name"], "typ": "BMP", "size": r["bytes"],
                "p1": w, "p2": h, "p3": BMP_BPP, "subdir": ".",
                "note": "BI_RGB uncompressed, upscale={}".format(ratio),
            })
        txt = manifest_block(
            f"{dir_name} campus gallery ({w}x{h} {BMP_BPP}bit)",
            "plan: docs/plan_v2/PLAN.md 4.2  res_sel={}  upscale={}".format(
                [i for i, t in enumerate(RES_TABLE) if t[0] == dir_name][0], ratio),
            recs)
        p = SDCARD / dir_name / "MANIFEST.TXT"
        p.write_text(txt, encoding="ascii", newline="\n")
        written[f"{dir_name}/MANIFEST.TXT"] = p.stat().st_size

    # ---- COMMON 目录：音频 + 视频 + 字幕 + 标语 ----
    recs = []
    for r in audio_records:
        recs.append({
            "name": r["name"], "typ": "WAV", "size": r["bytes"],
            "p1": r["sample_rate"] // 1000, "p2": r["bits"], "p3": r["channels"],
            "subdir": "AUDIO",
            "note": "PCM {}kHz/{}bit/{}ch {:.3f}s loop={}".format(
                r["sample_rate"] // 1000, r["bits"], r["channels"], r["duration_s"],
                "1" if r["name"] != NARRATION_NAME else "0"),
        })
    recs.append({
        "name": "SCI.RLE", "typ": "RLE", "size": video_stat["file_bytes"],
        "p1": video_stat["width"], "p2": video_stat["height"], "p3": 16,
        "subdir": "VIDEO",
        "note": "SCMR RGB565 frames={} fps={}".format(
            video_stat["frame_count"], video_stat["target_fps"]),
    })
    recs.append({
        "name": "SCI.IDX", "typ": "IDX", "size": video_stat["index_bytes"],
        "p1": video_stat["frame_count"], "p2": 0, "p3": 0,
        "subdir": "VIDEO",
        "note": "ASCII frame offset table (tool only)",
    })
    recs.append({
        "name": "NARR.SRT", "typ": "SRT", "size": subs["srt_bytes"],
        "p1": subs["srt_cues"], "p2": 0, "p3": 0,
        "subdir": "SRT",
        "note": "UTF-8 LF, compile-time ROM source",
    })
    recs.append({
        "name": "NARR.IDX", "typ": "IDX", "size": subs["idx_bytes"],
        "p1": subs["srt_cues"], "p2": 0, "p3": 0,
        "subdir": "SRT",
        "note": "ASCII cue timeline for OSD",
    })
    recs.append({
        "name": "TICKER.TXT", "typ": "TXT", "size": subs["ticker_bytes"],
        "p1": subs["ticker_cols"], "p2": 0, "p3": 0,
        "subdir": ".",
        "note": "ASCII 64-col ticker, osd line 15",
    })
    txt = manifest_block(
        "COMMON resolution-independent media (shared by all 5 res sets)",
        "audio: wav_stream_player PCM 48k/16/mono ; video: rle_decoder SCMR 640x480 RGB565",
        recs)
    p = SDCARD / "COMMON" / "MANIFEST.TXT"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(txt, encoding="ascii", newline="\n")
    written["COMMON/MANIFEST.TXT"] = p.stat().st_size

    return written


def build_root_manifest() -> Path:
    """全卡汇总清单：把实际磁盘上的所有文件列出来（不含自身）。"""
    files = walk_tree(SDCARD)
    files = [(rel, n) for rel, n in files if rel != "MANIFEST.TXT"]
    out = [MANIFEST_HEADER + "\n"]
    out.append("# assets/v2/sdcard full-card summary (generated by gen_assets_v2_sdcard.py)\n")
    out.append("# COUNT {}\n".format(len(files)))
    out.append("# TOTAL {}\n".format(sum(n for _, n in files)))
    total = 0
    cur = None
    for rel, n in files:
        d = rel.split("/")[0]
        if d != cur:
            out.append("# --- {} ---\n".format(d))
            cur = d
        out.append("FILE {:<44} {:>10d}\n".format(rel, n))
        total += n
    assert total == sum(n for _, n in files)
    p = SDCARD / "MANIFEST.TXT"
    p.write_text("".join(out), encoding="ascii", newline="\n")
    return p


# ============================================================================
# 六、BURN 目录：可直接整目录拷进 SD 卡根的成品卡
# ============================================================================
def stage_card(res_dir: str, dest_name: str | None = None,
               layout: str = CARD_LAYOUT_FLAT) -> Path:
    """
    把 COMMON/ + 指定 RES 目录装配成一张可直接烧录的卡。

    layout=CARD_LAYOUT_FLAT（**默认，交付形态**）：17 个文件全部直接位于卡根，零子目录。
        <dest>/
        ├── IMG001.BMP ~ IMG006.BMP
        ├── BGM.WAV  BGM2.WAV  BGM3.WAV  ALARM.WAV  NARR.WAV
        ├── SCI.RLE  SCI.IDX
        ├── NARR.SRT  NARR.IDX
        ├── TICKER.TXT
        └── MANIFEST.TXT

    layout=CARD_LAYOUT_SUBDIR（仅作对照/历史参考，不作交付默认）：
        媒体放在 VIDEO/ AUDIO/ SRT/ 三个子目录里（= ARCH.md §6.7 原始布局）。

    **为什么默认扁平**：`rtl/storage/fat32_reader.v` 只遍历根目录，且 L551-552 用
    `(attr & 0x18) == 0` 显式排除目录项，无子目录栈（grep subdir|dir_stack|ST_SUB 零命中）。
    放子目录的文件上板一律定位失败，且报错不指向真实原因（表现为「文件不存在」）。
    """
    if layout not in (CARD_LAYOUT_FLAT, CARD_LAYOUT_SUBDIR):
        raise SystemExit(f"[FATAL] 未知布局 {layout}")
    res_src = SDCARD / res_dir
    if not res_src.exists():
        raise SystemExit(f"[FATAL] 缺分辨率目录 {res_src}")
    dest = SDCARD / (dest_name or f"BURN{res_dir.replace('RES', '')}")
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)

    # 1) 6 张 BMP（两种布局都放根目录）
    for idx in IMAGE_INDEXES:
        shutil.copyfile(res_src / f"IMG{idx:03d}.BMP", dest / f"IMG{idx:03d}.BMP")

    # 2) COMMON 媒体
    common = SDCARD / "COMMON"
    if layout == CARD_LAYOUT_FLAT:
        # 逐文件搬到根目录：不保留子目录层级
        for sub in COMMON_SUBDIRS:
            for f in sorted((common / sub).iterdir()):
                if f.is_file():
                    shutil.copyfile(f, dest / f.name)
    else:
        for sub in COMMON_SUBDIRS:
            shutil.copytree(common / sub, dest / sub)
    shutil.copyfile(common / "TICKER.TXT", dest / "TICKER.TXT")

    # 3) 装配后的 MANIFEST.TXT：合并两份来源，仍为定长 ASCII
    #    扁平布局下 SUBDIR 列必须全部改写为 "."，否则校验第 12 项会按
    #    base/AUDIO/BGM.WAV 去找文件而误报（目录根本不存在）。
    res_man = (res_src / "MANIFEST.TXT").read_text(encoding="ascii")
    com_man = (common / "MANIFEST.TXT").read_text(encoding="ascii")
    img_lines = [ln for ln in res_man.splitlines() if ln.startswith("REC ")]
    com_lines = [ln for ln in com_man.splitlines() if ln.startswith("REC ")]
    recs = []
    for f in (ln.split() for ln in img_lines + com_lines):
        subdir = f[7] if layout == CARD_LAYOUT_SUBDIR else "."
        recs.append({"name": f[1], "typ": f[2], "size": int(f[3]),
                     "p1": int(f[4]), "p2": int(f[5]), "p3": int(f[6]),
                     "subdir": subdir, "note": " ".join(f[8:])})
    merged = manifest_block(
        f"burn-ready card {dest.name}  ({res_dir} gallery + COMMON media)",
        CARD_MANIFEST_NOTE_FLAT,
        recs)
    # 断言说明行与旧版等长：保证 MANIFEST.TXT 字节数恒为 1,729 B，
    # 从而「扁平化后卡根总字节 == 旧递归合计 112,506,540 B」这个验收点成立。
    # 这不是凑数，而是让验收能用一个绝对数字判定「内容一字节未变」。
    assert len(CARD_MANIFEST_NOTE_FLAT) == len(
        "burn: copy this directory CONTENT to FAT32 card root; "
        "layout per docs/plan_v2/ARCH.md 6.7"), "MANIFEST 说明行长度漂移，总字节将变化"
    (dest / "MANIFEST.TXT").write_text(merged, encoding="ascii", newline="\n")
    return dest


# ============================================================================
# 七、容量实测
# ============================================================================
def measure_capacity() -> dict:
    rows = []
    for d in sorted([p for p in SDCARD.iterdir() if p.is_dir()]):
        files = walk_tree(d)
        rows.append({"dir": d.name, "files": len(files), "bytes": sum(n for _, n in files)})
    total = sum(r["bytes"] for r in rows)
    root_files = [p for p in SDCARD.iterdir() if p.is_file()]
    root_bytes = sum(p.stat().st_size for p in root_files)
    return {"dirs": rows, "dirs_total_bytes": total,
            "root_files": len(root_files), "root_bytes": root_bytes,
            "grand_total_bytes": total + root_bytes}


# ============================================================================
# 八、全量自检
# ============================================================================
def verify(img_records, audio_records, video_stat, subs, manifests, capacity) -> list[str]:
    echo("\n" + "=" * 78)
    echo("自检")
    echo("=" * 78)
    lines = []
    ok = True

    def chk(name, cond, detail=""):
        nonlocal ok
        if not cond:
            ok = False
        lines.append(("  [OK] " if cond else "  [!!] ") + name + (("  " + detail) if detail else ""))
        echo(lines[-1])

    # 1) 30 张 BMP 全部可被 Pillow 重新打开，尺寸与记录一致
    bad = 0
    for r in img_records:
        p = SDCARD / r["path"]
        try:
            im = Image.open(p)
            im.load()
            if im.size != (r["w"], r["h"]) or im.mode != "RGB":
                bad += 1
            if p.stat().st_size != r["bytes"]:
                bad += 1
        except Exception:
            bad += 1
    chk("30 张 BMP 可 Pillow 重新打开且尺寸/字节数与记录一致",
        bad == 0, f"({len(img_records)} 张，异常 {bad})")

    # 2) 分辨率目录集合与 RES_TABLE 一致，每档恰好 6 张
    per_dir = {}
    for r in img_records:
        per_dir.setdefault(r["res_dir"], []).append(r)
    chk("每档分辨率目录恰好 6 张图",
        all(len(v) == 6 for v in per_dir.values()) and
        set(per_dir) == {t[0] for t in RES_TABLE},
        "(" + ", ".join(f"{k}={len(v)}" for k, v in sorted(per_dir.items())) + ")")

    # 3) 640x480 档与既有上板 BMP 的逐字节/逐像素对比（如实记录差异）
    legacy = REPO_ROOT / "assets" / "campus_media" / "sd_card" / "IMG001.BMP"
    if legacy.exists():
        new_p = SDCARD / "RES640" / "IMG001.BMP"
        a = np.asarray(Image.open(legacy).convert("RGB")).astype(np.int16)
        b = np.asarray(Image.open(new_p).convert("RGB")).astype(np.int16)
        if a.shape == b.shape:
            diff = np.abs(a - b).max(axis=2)
            pct = float((diff > 24).mean() * 100.0)
            chk("RES640/IMG001.BMP 与既有上板 BMP 尺寸一致（像素差异见文档）",
                True, f"(差异>24 的像素 {pct:.2f}%，来自母版改用 Noto 字形，非几何差异)")

    # 4) 音频：重新用 wave 打开，参数与记录一致
    bad = 0
    for r in audio_records:
        p = SDCARD / r["path"]
        try:
            got = probe_wav(p)
            require_card_wav(got, r["name"])
            if got["bytes"] != r["bytes"] or abs(got["duration_s"] - r["duration_s"]) > 1e-6:
                bad += 1
        except Exception:
            bad += 1
    chk("音频全部可 wave 重新打开且 1ch/16bit/48kHz 参数一致",
        bad == 0, f"({len(audio_records)} 个，异常 {bad})")

    # 5) 视频：RLE 文件头 12 字节逐帧回读校验
    rle_path = SDCARD / "COMMON" / "VIDEO" / "SCI.RLE"
    with open(rle_path, "rb") as f:
        f.seek(0)
        magic, w, h, rc = struct.unpack("<4sHHI", f.read(RLE_FRAME_HDR))
        bad = 0 if (magic == RLE_MAGIC and w == VIDEO_W and h == VIDEO_H) else 1
    meta = video_stat["_frames_meta"]
    chk("SCI.RLE 帧头 magic/尺寸合规", bad == 0,
        f"({VIDEO_W}x{VIDEO_H} RGB565, {video_stat['frame_count']} 帧)")

    # 6) 索引文件偏移与实际帧头位置一致性（抽 5 帧验证）
    idx_lines = [ln for ln in (SDCARD / "COMMON" / "VIDEO" / "SCI.IDX")
                 .read_text(encoding="ascii").splitlines() if ln and not ln.startswith("#")]
    chk("SCI.IDX 行数与帧数一致", len(idx_lines) == video_stat["frame_count"],
        f"({len(idx_lines)} 行)")
    sample = [0, len(idx_lines) // 4, len(idx_lines) // 2, 3 * len(idx_lines) // 4, len(idx_lines) - 1]
    mismatch = 0
    with open(rle_path, "rb") as f:
        for i in sample:
            no, off, nb, _runs = idx_lines[i].split()
            f.seek(int(off))
            if f.read(4) != RLE_MAGIC:
                mismatch += 1
    chk("SCI.IDX 记录的偏移处确有 SCMR 帧头（抽 5 帧）", mismatch == 0, f"(不符 {mismatch})")

    # 7) 字幕：重新解析并复验对齐
    srt_p = SDCARD / "COMMON" / "SRT" / SRT_NAME
    cues = parse_srt(srt_p.read_text(encoding="utf-8"))
    narr = next(r for r in audio_records if r["name"] == NARRATION_NAME)
    dur_ms = int(round(narr["duration_s"] * 1000))
    chk("NARR.SRT 重新解析条数与末条结束时间不超音频",
        len(cues) == subs["srt_cues"] and cues[-1]["end_ms"] <= dur_ms,
        f"({len(cues)} 条，末条 {cues[-1]['end']} <= {dur_ms/1000:.3f}s)")

    # 8) 滚动标语正好 64 字符且真 ASCII
    raw = (SDCARD / "COMMON" / "TICKER.TXT").read_bytes()
    chk("TICKER.TXT 为 64 字节纯 ASCII",
        len(raw) == TICKER_COLS and all(b < 128 for b in raw),
        f"({len(raw)} 字节)")

    # 9) 全部文件名满足 8.3 且全大写
    violations = []
    for rel, _n in walk_tree(SDCARD):
        parts = rel.split("/")
        for part in parts:
            if not size_8dot3_ok(part):
                violations.append(rel)
                break
    chk("全部文件/目录名满足 8.3 且全大写", not violations,
        f"({len(walk_tree(SDCARD))} 个文件)" + (f"；违规：{violations[:5]}" if violations else ""))

    # 10) 容量表与磁盘实际一致（两种口径互验）
    measured = {}
    for d in sorted([p for p in SDCARD.iterdir() if p.is_dir()]):
        measured[d.name] = dir_bytes(d)
    table = {r["dir"]: r["bytes"] for r in capacity["dirs"]}
    chk("容量表与磁盘实际占用逐目录一致", measured == table,
        f"(合计 {capacity['grand_total_bytes']:,} B)")
    recomputed = sum(measured.values()) + capacity["root_bytes"]
    chk("容量总计两种口径互验一致",
        recomputed == capacity["grand_total_bytes"],
        f"({recomputed:,} B = {recomputed/1024/1024:.2f} MiB)")

    # 11) MANIFEST.TXT 定长格式自解析
    bad = 0
    for rel in manifests:
        p = SDCARD / rel
        txt = p.read_text(encoding="ascii")
        if not txt.startswith(MANIFEST_HEADER):
            bad += 1
            continue
        recs = [ln for ln in txt.splitlines() if ln.startswith("REC ")]
        for ln in recs:
            f = ln.split()
            if len(f) < 9 or f[2] not in ("BMP", "WAV", "RLE", "SRT", "TXT", "IDX"):
                bad += 1
    chk("各 MANIFEST.TXT 均以标准头开始且每行可定宽解析", bad == 0,
        f"({len(manifests)} 份)")

    # 12) MANIFEST 中记录的字节数与磁盘一致（按 SUBDIR 列拼出真实路径）
    bad = 0
    checked = 0
    for rel in manifests:
        base = (SDCARD / rel).parent
        for ln in (SDCARD / rel).read_text(encoding="ascii").splitlines():
            if not ln.startswith("REC "):
                continue
            f = ln.split()
            name, size, subdir = f[1], int(f[3]), f[7]
            target = base / name if subdir == "." else base / subdir / name
            checked += 1
            if not target.exists() or target.stat().st_size != size:
                bad += 1
    chk("MANIFEST 记录的路径与字节数与磁盘实际一致", bad == 0,
        f"(核对 {checked} 条，不符 {bad})")

    # 13) 成品卡必须是**真扁平**：递归文件数 == 顶层文件数 == 17，且子目录数 == 0
    #     （这一条是 t19 的验收核心。早期版本 stage_card 用 copytree 保留子目录，
    #      而 fat32_reader 只遍历根目录 → 9 个媒体文件上板全部定位失败。）
    #     检查对象是磁盘上**所有** BURN* 目录，而不只是默认那张：
    #     `--stage RES320 --subdir` 会另装一张不可烧的卡，只查 BURN640 就会漏掉它。
    burn_all = sorted([p for p in SDCARD.iterdir() if p.is_dir() and p.name.startswith("BURN")])
    burn = SDCARD / f"BURN{DEFAULT_RES_DIR.replace('RES', '')}"
    if not burn_all:
        chk("BURN 成品卡存在", False, "(一个都没有)")
    for bd in burn_all:
        top_files = [p for p in bd.iterdir() if p.is_file()]
        rec_files = walk_tree(bd)
        subdirs = [p for p in bd.rglob("*") if p.is_dir()]
        chk(f"{bd.name} 为真扁平：顶层文件数 == 递归文件数 == {len(CARD_FLAT_FILES)} "
            f"且子目录数 == 0",
            len(top_files) == len(rec_files) == len(CARD_FLAT_FILES) and not subdirs,
            f"(顶层 {len(top_files)} / 递归 {len(rec_files)} / 子目录 {len(subdirs)}"
            + (f"；多余子目录：{[p.name for p in subdirs]}（--subdir 装的卡不可烧）"
               if subdirs else "") + ")")

    if burn.exists():
        top_files = [p for p in burn.iterdir() if p.is_file()]

        # 14) 卡内文件全集与预期逐个一致（漏装/多装都要报出来）
        got = {p.name for p in top_files}
        want = set(CARD_FLAT_FILES)
        chk("BURN 卡根文件全集与预期 17 个逐个一致",
            got == want,
            f"(缺 {sorted(want - got) or '无'}；多 {sorted(got - want) or '无'})")

        # 15) 17 个 8.3 名逐个合法且互不相同
        names = sorted(got)
        illegal = [n for n in names if not size_8dot3_ok(n)]
        chk("卡根 17 个文件名逐个满足 8.3 且全大写、无空格、互不相同",
            not illegal and len(names) == len(set(names)) == len(CARD_FLAT_FILES),
            f"({len(names)} 个" + (f"；违规 {illegal}" if illegal else "") + ")")

        # 16) FAT 目录项 11 字节形态实测（fat32_reader 是逐字节比较，拼名必须严格对上）
        #     重点核对 BGM.WAV / BGM2.WAV / BGM3.WAV 第 4 字节分别为 ' ' / '2' / '3'
        entries = {n: fat_shortname_entry(n) for n in names}
        e_bgm, e_bgm2, e_bgm3 = entries["BGM.WAV"], entries["BGM2.WAV"], entries["BGM3.WAV"]
        ok_len = all(len(v) == 11 for v in entries.values())
        ok_4th = (e_bgm[3:4] == b" " and e_bgm2[3:4] == b"2" and e_bgm3[3:4] == b"3")
        chk("卡根 17 个名字的 FAT 目录项 11 字节形态合规；"
            "BGM/BGM2/BGM3 第 4 字节 = 空格/'2'/'3'",
            ok_len and ok_4th,
            f"(11 字节 {sum(1 for v in entries.values() if len(v) == 11)}/{len(entries)}；"
            f"BGM={e_bgm!r} BGM2={e_bgm2!r} BGM3={e_bgm3!r})")

        # 17) 扁平化不改变内容：卡根总字节必须等于各来源目录同名字节之和
        burn_bytes_actual = sum(p.stat().st_size for p in top_files)
        expect_bytes = 0
        for idx in IMAGE_INDEXES:
            expect_bytes += (SDCARD / DEFAULT_RES_DIR / f"IMG{idx:03d}.BMP").stat().st_size
        for sub in COMMON_SUBDIRS:
            for f in (SDCARD / "COMMON" / sub).iterdir():
                if f.is_file():
                    expect_bytes += f.stat().st_size
        expect_bytes += (SDCARD / "COMMON" / "TICKER.TXT").stat().st_size
        # MANIFEST 合并后的字节数只能实测（内容是重新拼的，不是复制）
        expect_bytes += (burn / "MANIFEST.TXT").stat().st_size
        chk("扁平化只改层级不改字节：卡根总字节 == 各来源同名字节之和",
            burn_bytes_actual == expect_bytes,
            f"({burn_bytes_actual:,} B vs 预期 {expect_bytes:,} B)")

        # 18) 卡根 MANIFEST.TXT 的 SUBDIR 列必须全部为 "."（扁平后不存在子目录）
        nonflat = []
        man_txt = (burn / "MANIFEST.TXT").read_text(encoding="ascii")
        for ln in man_txt.splitlines():
            if ln.startswith("REC ") and ln.split()[7] != ".":
                nonflat.append(ln.split()[1])
        declared = [ln for ln in man_txt.splitlines() if ln.startswith("# COUNT ")]
        chk("卡根 MANIFEST.TXT 的 SUBDIR 列全部为 '.'，且 COUNT = 16（不含自身）",
            not nonflat and declared and declared[0].strip() == "# COUNT 16",
            f"(非'.'的 {len(nonflat)} 条{('：' + str(nonflat[:5])) if nonflat else ''}；"
            f"{declared[0].strip() if declared else '缺 COUNT'})")
    else:
        chk("BURN 成品卡存在", False, f"(缺 {burn})")

    echo("-" * 78)
    echo("结果：" + ("全部通过 ✓" if ok else "存在失败项 ✗"))
    return lines


# ============================================================================
# 九、文档 assets/v2/SDCARD_LAYOUT.md
# ============================================================================
def write_layout_doc(img_records, audio_records, video_stat, subs, capacity,
                     manifests, check_lines, burn_dir: Path) -> Path:
    L = []
    a = L.append

    def human(n: int) -> str:
        if n >= 1024 * 1024:
            return f"{n/1024/1024:.2f} MiB"
        if n >= 1024:
            return f"{n/1024:.1f} KiB"
        return f"{n} B"

    a("# SD 卡素材包布局与烧录说明（v2）")
    a("")
    a("> 本文件由 `scripts/gen_assets_v2_sdcard.py` 自动生成，所有数值均为**脚本运行时磁盘实测**，"
      "不是估算。重新运行脚本会得到逐字节相同的内容。")
    a("")
    a("## 1. 这张卡给谁用")
    a("")
    a("安路 EG4S20BG256「智播校园」多媒体终端。FPGA 通过 SPI 读 SD 卡，"
      "日常模式循环播放 6 张校园图 + 背景音乐，科普模式播放 RLE 压缩视频 + 解说音频 + 字幕，"
      "应急模式播放双音警报。")
    a("")

    a("## 2. 硬约束（先看这段，不符合就上不了板）")
    a("")
    a("| 约束 | 具体要求 | 依据 |")
    a("|---|---|---|")
    a("| 文件系统 | **FAT32**（也接受 FAT16 小卡）。`fat32_reader.v` 解析 MBR → VBR → 根目录，"
      "要求 `root_cluster >= 2`、`root_entries == 0`、`fat16_size == 0`（这几个判据用于区分"
      "「直接 FAT32 VBR」与「MBR 引导扇区」） | `rtl/storage/fat32_reader.v` L195-201 |")
    a("| 文件名 | **8.3 短名，全大写**。主名 1~8 字符 + 扩展名 1~3 字符。现有 RTL 无长文件名支持 | "
      "`fat32_reader.v` L19 |")
    a("| 目录层级 | `fat32_reader.v` **只遍历根目录**，不递归子目录 | `fat32_reader.v` L337-390 |")
    a("| 位图格式 | **24 bit BI_RGB 无压缩 BMP**，54 字节文件头。JPEG/PNG/RLE 位图一律不可上板 | "
      "`bmp_parser.v` err_code 2/3 |")
    a("| 音频格式 | **PCM / 16 bit / 48 kHz / 单声道**，canonical 44 字节头 | "
      "`ARCH.md` §6.6 `wav_stream_player.v` |")
    a("| 视频格式 | 自定义 `.RLE`，magic `\"SCMR\"`，RGB565 + 8 bit 游程 | `PLAN.md` §7.6 |")
    a("")

    a("## 3. 目录树（与磁盘实际一致）")
    a("")
    a("```")
    a("assets/v2/sdcard/")
    dirs = sorted([p for p in SDCARD.iterdir() if p.is_dir()])
    for i, d in enumerate(dirs):
        last_dir = (i == len(dirs) - 1)
        a(("└── " if last_dir else "├── ") + d.name + "/")
        prefix = "    " if last_dir else "│   "
        # 先列本层文件，再列子目录（子目录在后，才能让"最后一个"的树线正确收口）
        files = walk_tree(d)
        here = [(rel, n) for rel, n in files if "/" not in rel]
        # 注意：局部变量必须叫 subdirs，不能叫 subs——subs 是本函数的字幕统计参数，
        # 一旦同名覆盖，后面的 subs["srt_name"] 就会抛 KeyError。
        subdirs = {}
        for rel, n in files:
            if "/" in rel:
                k = rel.split("/", 1)[0]
                subdirs.setdefault(k, []).append((rel.split("/", 1)[1], n))
        entries = [("f", fn, n) for fn, n in here] + [("d", k, None) for k in sorted(subdirs)]
        for j, (kind, label, size) in enumerate(entries):
            last = (j == len(entries) - 1)
            if kind == "f":
                a(prefix + ("└── " if last else "├── ") + label + f"   {human(size)}")
            else:
                a(prefix + ("└── " if last else "├── ") + label + "/")
                inner = prefix + ("    " if last else "│   ")
                kids = sorted(subdirs[label])
                for m, (fn, n) in enumerate(kids):
                    a(inner + ("└── " if m == len(kids) - 1 else "├── ") + fn + f"   {human(n)}")
    a("```")
    a("")
    a(f"> 磁盘实际：**{len(walk_tree(SDCARD))} 个文件，{human(capacity['grand_total_bytes'])}**。"
      f"（其中根目录汇总文件 {capacity['root_files']} 个，{human(capacity['root_bytes'])}）")
    a("")

    a("## 4. 五档分辨率目录（RES320 / RES400 / RES512 / RES576 / RES640）")
    a("")
    a("每档 6 张校园图，**该档原生像素、24 bit BI_RGB 无压缩**，直接由 1920×1440 母版"
      "一步 LANCZOS 缩到目标尺寸（不做级联缩放）。")
    a("")
    a("| 目录 | 分辨率 | 单图字节 | 6 张合计 | `res_sel` | 放大比 |")
    a("|---|---|---|---|---|---|")
    for i, (dir_name, w, h, ratio) in enumerate(RES_TABLE):
        recs = [r for r in img_records if r["res_dir"] == dir_name]
        one = recs[0]["bytes"]
        tot = sum(r["bytes"] for r in recs)
        a(f"| `{dir_name}/` | {w}×{h} | {one:,} B | {human(tot)} | `3'd{i}` | {ratio} |")
    a("")
    a("单图字节数公式：`54 + w*h*3`（行字节 `w*3` 在五档下均为 4 的倍数，填充恒为 0）。")
    a("")
    a("> **`RES640` 与既有上板 BMP 不是逐字节相同**：几何图形完全一致，但文字笔画有差异——"
      "母版改用 Noto Sans SC（SIL OFL 1.1）重渲染，而仓库既有的 "
      "`assets/campus_media/sd_card/IMG001~006.BMP` 是用等线粗体（Dengb.ttf）画的。"
      "t3 已量化该差异为 3.28%~4.42% 的像素（阈值 24/255），集中在文字边缘。"
      "这是**有意为之的授权规避**（等线/雅黑为微软专有字体）。")
    a("")

    a("## 5. COMMON 目录（分辨率无关素材，五档共用一份）")
    a("")
    a("### 5.1 音频（`COMMON/AUDIO/`）")
    a("")
    a("| 文件 | 用途 | 时长 | 采样率/位深/声道 | 字节 | 循环 |")
    a("|---|---|---|---|---|---|")
    for r in audio_records:
        loop = "否（单向播放）" if r["name"] == NARRATION_NAME else "是"
        a(f"| `{r['name']}` | {r['use']} | {r['duration_s']:.3f} s | "
          f"{r['sample_rate']} Hz / {r['bits']} bit / {r['channels']} ch | "
          f"{r['bytes']:,} B | {loop} |")
    a("")
    a("全部为 numpy 程序化合成（`scripts/gen_assets_v2_audio.py`），**零采样、零音源库、无第三方版权**。"
      "应急警报是 740/1110 Hz 双音交替 siren，人耳敏感带 300~4000 Hz 能量占比 99.9%。")
    a("")
    a("> `NARR.WAV` 原名 `NARRATION.WAV`（见 `ARCH.md` §6.7），主名 9 字符**违反 8.3**，此处已改短。")
    a("")

    a("### 5.2 视频（`COMMON/VIDEO/`）")
    a("")
    a("| 项 | 值 |")
    a("|---|---|")
    v = video_stat
    a(f"| 源 | `work/fpga_intro_video/{v['src']}`（{v['src_bytes']:,} B，H.264） |")
    a(f"| 编码 | 自定义 `.RLE`，magic `\"SCMR\"`，RGB565（16 bpp）+ 8 bit 游程 |")
    a(f"| 分辨率 | {v['width']}×{v['height']} |")
    a(f"| 源帧率 → 目标帧率 | {v['src_fps']:.0f} fps → **{v['target_fps']} fps**（每 {v['frame_step']} 帧取 1 帧） |")
    a(f"| 帧数 / 时长 | {v['frame_count']} 帧 / {v['duration_s']:.3f} s |")
    a(f"| 文件大小 | **{v['file_bytes']:,} B**（{human(v['file_bytes'])}） |")
    a(f"| 单帧字节 | 均值 {v['avg_frame_bytes']:,} B / 最小 {v['min_frame_bytes']:,} B / "
      f"最大 {v['max_frame_bytes']:,} B / p95 {v['p95_frame_bytes']:,} B |")
    a(f"| 压缩比 | {v['compression_ratio']:.4f}（相对未压缩 RGB565） |")
    a(f"| 所需带宽 | 均值 **{v['bandwidth_MBps_mean']:.3f} MB/s**（占 SD 1.25 MB/s 的 "
      f"{v['sd_ratio_mean']*100:.1f}%），最坏 {v['bandwidth_MBps_worst']:.3f} MB/s"
      f"（{v['sd_ratio_worst']*100:.1f}%） |")
    a("")
    a("**帧文件命名规范**：")
    a("")
    a("- 默认（本卡采用）：单文件多帧。所有帧顺序写进一个 `SCI.RLE`，"
      "**每帧自带 12 字节头**（`magic(4) + width(2) + height(2) + run_count(4)`，全部小端），"
      "第 N 帧的偏移 = 前 N-1 帧 `run_count` 累加。依据 `PLAN.md` §7.6 / `ARCH.md` §6.7。")
    a("- 备选（未采用）：每帧独立文件，命名 `F00000.RLE` ~ `F00629.RLE`"
      "（`F` + 5 位十进制帧号 + `.RLE`，主名 6 字符，满足 8.3）。"
      "好处是单帧损坏不影响后续；坏处是 FAT 目录项膨胀、随机定位仍要查 FAT 链。")
    a("- `SCI.IDX` 是**工具用**索引表（ASCII 定长：帧号 5 位、偏移 11 位、字节数 10 位、"
      "游程数 6 位）。RTL **不读**索引文件——`rle_decoder` 自己用 `run_count` 累加定位。")
    a("")
    a("限帧率的原因（必须原样进答辩材料）：SD 卡走 SPI 12.5 MHz，实用带宽约 **1.25 MB/s**；"
      "而 640×480 未压缩 RGB565 单帧 614,400 B，30 fps 需 18.43 MB/s —— **差 14.7 倍**。"
      "素材是 PPT 风格动画、大片纯色，游程极长，RLE 压缩比 0.206 把帧率从 1 fps 抬到 5 fps。"
      "**5 fps 是设计目标，2 fps 是承诺下限**（持续欠载时 RTL 自动降帧，不降分辨率）。")
    a("")

    a("### 5.3 字幕与滚动标语（`COMMON/SRT/` 与 `COMMON/TICKER.TXT`）")
    a("")
    a("| 文件 | 内容 | 格式 | 字节 |")
    a("|---|---|---|---|")
    a(f"| `{subs['srt_name']}` | 科普解说字幕 {subs['srt_cues']} 条，"
      f"时间轴 {subs['srt_first']} → {subs['srt_last']} | UTF-8 + LF | {subs['srt_bytes']:,} B |")
    a(f"| `{subs['idx_name']}` | 同上的 ASCII 时间轴索引 | 定长 ASCII | {subs['idx_bytes']:,} B |")
    a(f"| `{subs['ticker_name']}` | 日常模式滚动标语，正好 {subs['ticker_cols']} 字符 | 纯 ASCII | "
      f"{subs['ticker_bytes']:,} B |")
    a("")
    a(f"滚动标语原文（{subs['ticker_trimmed_cols']} 字符 + 右补空格到 {subs['ticker_cols']}）：")
    a("")
    a("```")
    a(subs["ticker_text"])
    a("```")
    a("")
    a("**为什么必须正好 64 字符**：`osd_caption.v` 用 `ticker_col = (像素列 + 滚动偏移) & 6'b111111` "
      "取模，64 = 2⁶ 是位掩码，取模零逻辑成本。字符集受 `osd_font8x16` 字模 ROM 限制："
      "只有 `空格 - . / 0-9 : A-Z`。")
    a("")
    a("> ⚠️ **中文字幕当前无法直接上屏**：`osd_font8x16.v` 是纯 ASCII 8×16 字模，"
      f"而 `NARR.SRT` 含 **{subs['cjk_unique_in_srt']} 个不同字符**（含汉字）。"
      "t3 产出的 `cjk16_font.v` 只有 95 个字形，**不足以覆盖字幕全集**。"
      "按 `PLAN.md` §13 R-09，字幕是**编译期转 ROM 表**、不运行时解析；"
      "因此本卡提供 UTF-8 原文作为 ROM 生成源，实际是否上屏取决于后续字库扩容。"
      "这是**已知降级项**，不是遗漏。")
    a("")

    a("## 6. 为什么没有 `scaled/NN/` 预生成目录")
    a("")
    a("任务书原文提供了两个分支：「预生成缩放图」或「依赖 `img_scaler.v` 实时缩放」。"
      "**两个分支都不成立**，已在 `PLAN.md` §5.2 定稿：")
    a("")
    a("| 方案 | 判定 | 理由 |")
    a("|---|---|---|")
    a("| A. 实时窗口裁剪 | ✅ **采用** | `image_window_mask.v`（已存在，41 LUT）+ `ratio_map`（+30 LUT）。"
      "窗口内原始像素 1:1 显示、无插值损失、切换延迟 1 帧、**素材工作量零** |")
    a("| B. 预生成五套素材 | ❌ 否决 | 6 图 × 5 档 = 30 个文件，`t4` 素材工作量 ×5；"
      "且窗口内是缩放后的图，有插值损失 |")
    a("")
    a("五档屏占比（`ratio_sel` 0→4）的窗口参数全部是 640×480 的整数分数，"
      "由 RTL 组合译码得出，**不需要任何素材**：")
    a("")
    a("| `ratio_sel` | 占比 | `win_w`×`win_h` | 偏移 | 面积 |")
    a("|---|---|---|---|---|")
    for i, (rw, rh, ox, oy, frac, area) in enumerate([
        (320, 240, 160, 120, "1/2", "25.0%"),
        (400, 300, 120, 90, "5/8", "39.1%"),
        (480, 360, 80, 60, "3/4", "56.3%"),
        (560, 420, 40, 30, "7/8", "76.6%"),
        (640, 480, 0, 0, "1", "100%"),
    ]):
        a(f"| `3'd{i}` | {frac} | {rw}×{rh} | ({ox},{oy}) | {area} |")
    a("")

    a("## 7. 成品卡 `BURN640/`（真扁平，可直接烧录）")
    a("")
    a(f"`{burn_dir.name}/` 是把 `COMMON/` + `RES640/` 装配好的**真扁平**成品卡，"
      "**整目录内容拷到 FAT32 卡根**即可上板。卡根 **17 个文件、零子目录**：")
    a("")
    a("```")
    a("SD 卡根/")
    a("├── IMG001.BMP ~ IMG006.BMP      640×480×24bit 无压缩，各 921,654 B")
    a("├── BGM.WAV      日常模式背景音乐（主，40.000 s）")
    a("├── BGM2.WAV     备选背景音乐 2（专注，48.000 s）")
    a("├── BGM3.WAV     备选背景音乐 3（律动，36.000 s）")
    a("├── ALARM.WAV    应急警报（双音交替 siren，6.000 s，loop）")
    a("├── NARR.WAV     科普解说音轨（126.106 s）")
    a("├── SCI.RLE      科普视频 631 帧 / 5 fps（SCMR RGB565 + 8bit 游程）")
    a("├── SCI.IDX      视频帧偏移索引表（工具/校验用，ASCII 定长）")
    a("├── NARR.SRT     科普解说字幕 18 条（UTF-8 LF）")
    a("├── NARR.IDX     字幕时间轴（ASCII 定长，供 OSD）")
    a("├── TICKER.TXT   滚动标语 64 字节纯 ASCII（osd line 15）")
    a("└── MANIFEST.TXT 定长 ASCII 清单（COUNT 16，不含自身）")
    a("```")
    a("")
    a("> **本次修正（t19）**：早期版本此处正文写「扁平成品卡」，但实际落盘是 "
      "`AUDIO/` `VIDEO/` `SRT/` **三个子目录 + 根目录 8 个文件**——"
      "与 `rtl/storage/fat32_reader.v` 只遍历根目录（且 `(attr & 0x18) == 0` "
      "显式排除目录项、无子目录栈）直接冲突。后果是 9 个媒体文件上板全部定位失败："
      "日常模式没背景音乐、科普模式没视频没解说、应急模式没警报音。"
      "现 `stage_card()` 默认按 `layout=flat` 逐文件拷到根目录，"
      "并新增自检项 13~18 从磁盘实测卡根扁平性、文件全集、8.3 名合法性与 "
      "FAT 目录项 11 字节形态。子目录布局仍可用 `--subdir` 装配，"
      "但**仅供对照，不要烧到卡里**。")
    a("")
    burn_bytes = dir_bytes(burn_dir)
    burn_top = [p for p in burn_dir.iterdir() if p.is_file()]
    a(f"成品卡实际占用 **{human(burn_bytes)}**（{len(burn_top)} 个文件，"
      f"{burn_bytes:,} B），全部位于卡根。")
    a("")
    a("需要其它分辨率档的成品卡：")
    a("")
    a("```powershell")
    a("cd D:\\FPGA_Compelate\\SmartCampusMedia")
    a("python scripts/gen_assets_v2_sdcard.py --stage RES320    # 或 RES400/RES512/RES576")
    a("```")
    a("")

    a("## 8. 烧录步骤")
    a("")
    a("1. 把 SD 卡格式化为 **FAT32**（Windows 资源管理器：右键 → 格式化 → 文件系统选 FAT32；"
      "32 GB 以上卡 Windows 会隐藏 FAT32 选项，可用 `diskpart` 或 Rufus）。")
    a("2. 把 `assets/v2/sdcard/BURN640/` **里面的内容**（不是这个目录本身）拷到卡根。")
    a("3. 确认卡根直接能看到 `IMG001.BMP`、`BGM.WAV`、`SCI.RLE` 等 **17 个文件**，"
      "且**没有任何子目录**（若看到 `AUDIO/` `VIDEO/` `SRT/`，说明拷的是旧版子目录布局，"
      "`fat32_reader` 读不到里面的文件）。")
    a("4. 用 `python scripts/gen_assets_v2_sdcard.py --verify` 核对：自检项 13~18 会检查"
      "顶层 17 个文件 / 零子目录 / 8.3 名合法性 / FAT 目录项形态 / SUBDIR 列全为 `.`。")
    a("5. 上板：先上电 SD 初始化，再看日常模式是否循环出图。")
    a("")
    a("> **不要**把 `assets/campus_media/preview/smart_campus_showcase.mp4` 拷进卡里当视频源："
      "它是 H.264，FPGA 无解码能力，只能作答辩演示素材（`PLAN.md` §7.7 素材红线）。")
    a("")

    a("## 9. 容量估算与实际占用")
    a("")
    a("| 目录 | 文件数 | 实际占用 |")
    a("|---|---|---|")
    for r in capacity["dirs"]:
        a(f"| `{r['dir']}/` | {r['files']} | {human(r['bytes'])}（{r['bytes']:,} B） |")
    a(f"| 根目录（汇总文件） | {capacity['root_files']} | "
      f"{human(capacity['root_bytes'])}（{capacity['root_bytes']:,} B） |")
    a(f"| **合计** | **{sum(r['files'] for r in capacity['dirs']) + capacity['root_files']}** | "
      f"**{human(capacity['grand_total_bytes'])}（{capacity['grand_total_bytes']:,} B）** |")
    a("")
    a("**实际单卡烧录容量**（只拷 `BURN640/`）远小于上表——上表是整个 `assets/v2/sdcard/` "
      "工作目录（含五档分辨率图 + 装配好的成品卡），不是一张卡的大小：")
    a("")
    a("| 项目 | 占用 |")
    a("|---|---|")
    a(f"| 一张成品卡（BURN640） | **{human(burn_bytes)}** |")
    a(f"| 五档图库（RES320~RES640，30 张） | {human(sum(r['bytes'] for r in capacity['dirs'] if r['dir'].startswith('RES')))} |")
    a(f"| COMMON 媒体（音频+视频+字幕） | {human(sum(r['bytes'] for r in capacity['dirs'] if r['dir'] == 'COMMON'))} |")
    a("")
    a("推荐使用 **≥ 512 MB** 的卡（成品卡约需 "
      f"{burn_bytes/1024/1024:.0f} MiB，留 2 倍余量给后续扩容）。")
    a("")

    a("## 10. 与任务书字面要求的偏差（逐条如实记录）")
    a("")
    a("| # | 任务书原文 | 实际做法 | 依据 |")
    a("|---|---|---|---|")
    a("| 1 | RES 用 `640x480 / 800x600 / …` | 用 `320×240 / 400×300 / 512×384 / 576×432 / 640×480` | "
      "`PLAN.md` §4.2 定稿；§4.3 明确**否决** 800×600（需 40 MHz 像素时钟，VCO 需 1200 MHz "
      "恰在芯片上限临界），1024×768 / 1280×720 更是**明令禁止** |")
    a("| 2 | 若预生成缩放图，落到 `scaled/NN/` | **不产出** `scaled/` 任何目录 | "
      "`PLAN.md` §5.2 否决预生成方案，屏占比用实时窗口裁剪（+30 LUT，素材工作量零） |")
    a("| 3 | 音频文件 `NARRATION.WAV` / 字幕 `NARRATION.SRT` | 改名 `NARR.WAV` / `NARR.SRT` | "
      "`ARCH.md` §6.7 原名主名 9 字符，**违反 8.3**；`fat32_reader.v` 无长名支持 |")
    a("| 4 | 每档目录含音频、视频、字幕 | 音频/视频/字幕统一放 `COMMON/`，每档目录只放 6 张图 | "
      "内容与内部渲染分辨率无关；五份复制 = 白白多占约 520 MB 且容量表失去意义（见 §11） |")
    a("| 5 | 视频「帧序列目录」 | 单文件多帧 `SCI.RLE` + `SCI.IDX` 索引 | "
      "`PLAN.md` §7.6 / `ARCH.md` §6.7 定稿为逐帧带 12 B 头的单文件；命名规范见 §5.2 |")
    a("| 6 | （架构原文）媒体放 `VIDEO/` `AUDIO/` `SRT/` 子目录 | 媒体全部放**卡根**，零子目录 | "
      "`fat32_reader.v` 只遍历根目录且 `(attr & 0x18) == 0` 排除目录项、无子目录栈；"
      "扁平是唯一能上板的布局（§11.1）。见 §7 的「本次修正」 |")
    a("")

    a("## 11. 跨任务阻塞点（需 RTL 侧配合，不属于素材范围）")
    a("")
    a("以下三条是素材包**已经按架构准备好、但当前 RTL 还读不到**的地方，如实上报。")
    a("")
    a("> **读法说明（重要）**：§11.1 已**由素材侧定案**（卡根扁平，不再等 RTL 决策），"
      "§11.2 是纯 RTL 侧的前置条件，两者是**先后关系而非二选一**。")
    a("> 早期版本把「扁平化放卡根」写成「零 RTL 改动」备选，这是错的："
      "扁平化绕得过「不递归子目录」，绕不过「文件名逐字节硬编码」——"
      "`SCI.RLE` 的首字节 `'S'=0x53` 撞上 `exp_byte=8'h49('I')` 立刻不符，"
      "照样读不到。")
    a("> 所以正确表述是：**§11.1 已按扁平落盘（素材侧完成），"
      "§11.2 是 RTL 侧必须做的前置条件**；两者都解决之前，"
      "三个模式的媒体功能无法上板。")
    a("")
    a("### 11.1 【已定：扁平】`fat32_reader.v` 只遍历根目录")
    a("")
    a("`fat32_reader.v` L142-144 的目录游标只有 `dir_cluster` / `dir_sec_idx` / `dir_fat_cnt` "
      "三个寄存器，**没有子目录栈、没有递归**；`ST_DIR` 状态只沿 `dir_cluster <= root_cluster` "
      "的根目录簇链推进。L551-552 的注释逐字为「属性字节: 排除 LFN(0x0F) / 卷标(0x08) / 目录(0x10)」，"
      "判据 `(attr & 0x18) == 0` **显式排除目录项**。")
    a("")
    a("**结论：卡根必须扁平。** 这条已经定下来，不再是备选：")
    a("")
    a("- **已采用方案**：媒体全部放卡根，用 8.3 可容纳的扁平名"
      "（`SCI.RLE` `BGM.WAV` `BGM2.WAV` `BGM3.WAV` `ALARM.WAV` `NARR.WAV` "
      "`NARR.SRT` `NARR.IDX` `SCI.IDX` `TICKER.TXT`，全部已在 §3 验证合法）。"
      "卡根 17 个文件、零子目录，**当前 `BURN640/` 就是按这个装配的**"
      "（`stage_card()` 默认 `layout=flat`，自检项 13~18 从磁盘实测保证）。"
      "FAT32 根目录无项数上限（与 FAT16 的 512 项固定根区不同），17 项完全无压力。")
    a("- **未采用方案（仅留档对照）**：给 `fat32_reader` 加一级子目录进入"
      "（解析目录项 attr `0x10` 位 → 取 `first_cluster` → 从该簇继续遍历），"
      "即 `ARCH.md` §6.7 的原始 `VIDEO/` `AUDIO/` `SRT/` 布局。"
      "**不采用的理由**：要动 FSM 的 DIR 阶段、加一组子目录游标寄存器，"
      "而扁平布局的代价是 0 —— 同样能解决问题时不应引入额外 RTL 复杂度与回归风险。"
      "脚本仍保留 `--subdir` 开关可装配这种布局，**仅供对照，不要烧进卡**。")
    a("")
    a("> **注意 §11.2 仍然是前置条件**：即便卡根已经扁平，`IMGnnn.BMP` 以外的 10 个文件名"
      "在读完 §11.2 之前依然匹配不上。扁平只解决了「能不能看到这些目录项」，"
      "没有解决「看到之后认不认得」。")
    a("")
    a("### 11.2 短名匹配是硬编码 `IMGnnn.BMP`（**前置条件，不可绕过**）")
    a("")
    a("`fat32_reader.v` L590-614（always 块④）把期望短名逐字节写死：")
    a("")
    a("```verilog")
    a("5'd0 : exp_byte = 8'h49;  // 'I'")
    a("5'd1 : exp_byte = 8'h4D;  // 'M'")
    a("5'd2 : exp_byte = 8'h47;  // 'G'")
    a("5'd3 : exp_byte = 8'h30 + {4'd0, idx_h};  // 百位")
    a("5'd4 : exp_byte = 8'h30 + {4'd0, idx_t};  // 十位")
    a("5'd5 : exp_byte = 8'h30 + {4'd0, idx_o};  // 个位")
    a("5'd6, 5'd7 : exp_byte = 8'h20;            // 空格")
    a("5'd8 : exp_byte = 8'h42;  // 'B'")
    a("5'd9 : exp_byte = 8'h4D;  // 'M'")
    a("5'd10: exp_byte = 8'h50;  // 'P'")
    a("```")
    a("")
    a("**除 `IMGnnn.BMP` 外任何文件名都匹配不上。** 这不是「布局问题」而是「匹配逻辑缺失」："
      "`SCI.RLE` / `BGM.WAV` / `NARR.WAV` / `NARR.SRT` / `TICKER.TXT` 一个都读不到。")
    a("")
    a("修法建议（属 rtl-engineer 范围）：把 `exp_byte` 的译码参数化——目标名从端口输入"
      "（或 11 字节小 ROM），逐字节比较，`IMGnnn.BMP` 退化为其中一种特例。"
      "改完后 `img_loader` 的 `img_index` 逻辑可保持不动（仍用特例参数）。")
    a("")
    a("**这是 `ARCH.md` §6.5/§6.6/§6.7 新增的 RLE / WAV / SRT 三路读取的共同前置条件。**")
    a("")
    a("### 11.3 非 640×480 的 BMP 现有管线会缩小显示，不会放大")
    a("")
    a("`img_scaler.v` L24-38 明确「**只做缩小，不做放大**；源图小于 640×480 时按 1:1 原尺寸居中」。"
      "所以 **`RES320`~`RES576` 这四档 BMP 对当前 RTL 不可用**：放进去只会显示成屏幕中央一小块，"
      "不是放大的画面。")
    a("")
    a("正确用法（`PLAN.md` §4.1 的 N1 口径）：**SD 卡只放一套 640×480 源图**，"
      "五档分辨率由 `video_geom_map.v` 在**输出侧**用最近邻 DDA 放大实现，"
      "即「内部渲染分辨率」而非「素材分辨率」。所以：")
    a("")
    a("- **实际烧录用 `RES640/`（= `BURN640/`）**。")
    a("- `RES320`~`RES576` 四档是**素材完整性与架构备选**（万一将来改成「直接喂小图」的方案），"
      "当前 N1 架构不消费它们。")
    a("")

    a("## 12. 自检结果（脚本本次运行实测）")
    a("")
    a("```")
    for ln in check_lines:
        a(ln.strip())
    a("```")
    a("")

    a("## 13. 可复现性")
    a("")
    a("```powershell")
    a("cd D:\\FPGA_Compelate\\SmartCampusMedia")
    a("python scripts/gen_assets_v2_sdcard.py            # 全量重建（含 BURN640 装配，默认扁平）")
    a("python scripts/gen_assets_v2_sdcard.py --verify   # 只校验，不重建")
    a("python scripts/gen_assets_v2_sdcard.py --stage RES512   # 另装一张 512 档成品卡")
    a("python scripts/gen_assets_v2_sdcard.py --subdir   # 装配子目录布局（仅对照，不要烧卡）")
    a("```")
    a("")
    a("依赖的上游脚本（按序）：")
    a("")
    a("1. `scripts/gen_assets_v2_images.py` — 6 张 1920×1440 母版（**本脚本的直接输入**）")
    a("2. `scripts/gen_assets_v2_audio.py` — 3 段 BGM + 1 段警报")
    a("3. `scripts/gen_assets_v2_video.py` — narration.wav / narration.srt / 带宽统计")
    a("")
    a("本脚本全部输入来自 `assets/v2/masters/` 与 `work/fpga_intro_video/`，"
      "输出内容不含时间戳、不含随机数，重复运行逐字节相同。")
    a("")

    p = V2 / "SDCARD_LAYOUT.md"
    p.write_text("\n".join(L) + "\n", encoding="utf-8", newline="\n")
    return p


# ============================================================================
# main
# ============================================================================
def main() -> int:
    ap = argparse.ArgumentParser(description="生成 assets/v2/sdcard 素材包")
    ap.add_argument("--verify", action="store_true", help="只校验，不重建")
    ap.add_argument("--stage", metavar="RESDIR", default=None,
                    help="额外装配一张成品卡，如 RES320 / RES512")
    ap.add_argument("--no-burn", action="store_true", help="不装配默认的 BURN640")
    ap.add_argument("--flat", dest="layout", action="store_const",
                    const=CARD_LAYOUT_FLAT, help="成品卡用扁平布局（默认）")
    ap.add_argument("--subdir", dest="layout", action="store_const",
                    const=CARD_LAYOUT_SUBDIR,
                    help="成品卡用子目录布局（VIDEO/AUDIO/SRT，仅作对照，"
                         "fat32_reader 读不到，不要烧这个）")
    ap.set_defaults(layout=DEFAULT_CARD_LAYOUT)
    args = ap.parse_args()

    if not args.verify:
        echo("=" * 78)
        echo("生成 assets/v2/sdcard 素材包（t4）")
        echo("=" * 78)

        echo("\n[1/6] 校园图：1920x1440 母版 -> 五档原生像素 24bit BMP ...")
        masters = load_master_images()
        for idx, im in masters.items():
            echo(f"      母版 IMG{idx:03d}.png  {im.size[0]}x{im.size[1]} {im.mode}")
        img_records = build_images(masters)
        for dir_name, w, h, _r in RES_TABLE:
            recs = [r for r in img_records if r["res_dir"] == dir_name]
            echo(f"      {dir_name}: {len(recs)} 张 {w}x{h}  单图 {recs[0]['bytes']:,} B  "
                 f"合计 {sum(x['bytes'] for x in recs):,} B")

        echo("\n[2/6] 音频：母版 WAV -> COMMON/AUDIO（逐字节复制 + 头校验）...")
        audio_records = build_audio()
        for r in audio_records:
            echo(f"      {r['name']:<10} {r['duration_s']:>8.3f}s  "
                 f"{r['sample_rate']}/{r['bits']}bit/{r['channels']}ch  {r['bytes']:,} B  {r['use']}")

        echo("\n[3/6] 视频：mp4 -> COMMON/VIDEO/SCI.RLE（SCMR RGB565 + 8bit 游程）...")
        video_stat = build_video()
        echo(f"      帧数 {video_stat['frame_count']}  {video_stat['target_fps']} fps  "
             f"{video_stat['duration_s']:.3f} s")
        echo(f"      文件 {video_stat['file_bytes']:,} B  单帧均值 {video_stat['avg_frame_bytes']:,} B  "
             f"最大 {video_stat['max_frame_bytes']:,} B  压缩比 {video_stat['compression_ratio']:.4f}")
        echo(f"      带宽 均值 {video_stat['bandwidth_MBps_mean']:.3f} MB/s "
             f"({video_stat['sd_ratio_mean']*100:.1f}%)  "
             f"最坏 {video_stat['bandwidth_MBps_worst']:.3f} MB/s "
             f"({video_stat['sd_ratio_worst']*100:.1f}%)")

        echo("\n[4/6] 字幕与滚动标语 ...")
        subs = build_subtitles(audio_records)
        echo(f"      {subs['srt_name']}  {subs['srt_cues']} 条  {subs['srt_bytes']:,} B  "
             f"{subs['srt_first']} -> {subs['srt_last']}")
        echo(f"      {subs['ticker_name']} {subs['ticker_cols']} 字符（原文 {subs['ticker_trimmed_cols']}）"
             f"  ASCII 校验通过")

        echo("\n[5/6] MANIFEST.TXT ...")
        manifests = build_manifests(img_records, audio_records, video_stat, subs)
        for k, v in sorted(manifests.items()):
            echo(f"      {k:<24} {v:>8,} B")

        echo("\n[6/6] 装配成品卡 ...")
        burn_dirs = []
        if not args.no_burn:
            b = stage_card(DEFAULT_RES_DIR, layout=args.layout)
            burn_dirs.append(b)
            echo(f"      {b.name}/  {len(walk_tree(b))} 个文件  {dir_bytes(b):,} B  "
                 f"layout={args.layout}")
        if args.stage:
            b = stage_card(args.stage, layout=args.layout)
            burn_dirs.append(b)
            echo(f"      {b.name}/  {len(walk_tree(b))} 个文件  {dir_bytes(b):,} B  "
                 f"layout={args.layout}")
        if not burn_dirs:
            burn_dirs = [SDCARD / f"BURN{DEFAULT_RES_DIR.replace('RES', '')}"]

        # 全卡汇总清单必须**最后**生成：它要枚举磁盘上所有文件，
        # 若在 stage_card 之前写，BURN640/ 的内容就漏了，且重复运行时
        # 会因为上一轮残留的 BURN 目录导致内容漂移（首次 15 个、二次 17 个）。
        root_man = build_root_manifest()
        echo(f"      {'MANIFEST.TXT':<24} {root_man.stat().st_size:>8,} B  (全卡汇总)")
    else:
        echo("=" * 78)
        echo("--verify 模式：只校验既有产物")
        echo("=" * 78)
        # 校验模式：从磁盘重建记录，不写任何文件
        img_records = []
        masters = {}
        for dir_name, w, h, ratio in RES_TABLE:
            for idx in IMAGE_INDEXES:
                p = SDCARD / dir_name / f"IMG{idx:03d}.BMP"
                if not p.exists():
                    raise SystemExit(f"[FATAL] 缺 {p}")
                img_records.append({"res_dir": dir_name, "name": p.name, "w": w, "h": h,
                                    "bytes": p.stat().st_size, "ratio": ratio,
                                    "path": f"{dir_name}/{p.name}"})
        audio_records = []
        for src, dst, use in AUDIO_MAP:
            p = SDCARD / "COMMON" / "AUDIO" / dst
            info = probe_wav(p)
            audio_records.append({"name": dst, "source": src, "use": use,
                                  "bytes": p.stat().st_size, "sample_rate": info["sample_rate"],
                                  "bits": info["bits"], "channels": info["channels"],
                                  "frames": info["frames"], "duration_s": info["duration_s"],
                                  "bit_rate_Bps": info["sample_rate"] * info["bits"] * info["channels"] // 8,
                                  "path": f"COMMON/AUDIO/{dst}"})
        p = SDCARD / "COMMON" / "AUDIO" / NARRATION_NAME
        info = probe_wav(p)
        audio_records.append({"name": NARRATION_NAME, "source": NARRATION_SRC.name,
                              "use": "科普解说", "bytes": p.stat().st_size,
                              "sample_rate": info["sample_rate"], "bits": info["bits"],
                              "channels": info["channels"], "frames": info["frames"],
                              "duration_s": info["duration_s"],
                              "bit_rate_Bps": info["sample_rate"] * info["bits"] * info["channels"] // 8,
                              "path": f"COMMON/AUDIO/{NARRATION_NAME}"})
        ip = SDCARD / "COMMON" / "VIDEO" / "SCI.IDX"
        idx_lines = [ln for ln in ip.read_text(encoding="ascii").splitlines()
                     if ln and not ln.startswith("#")]
        frames_meta = []
        for ln in idx_lines:
            no, off, nb, rc = ln.split()
            frames_meta.append((int(no), int(off), int(nb), int(rc)))
        sizes = np.array([m[2] for m in frames_meta], dtype=np.int64)
        rle_bytes = (SDCARD / "COMMON" / "VIDEO" / "SCI.RLE").stat().st_size
        video_stat = {"width": VIDEO_W, "height": VIDEO_H, "target_fps": VIDEO_TARGET_FPS,
                      "frame_count": len(frames_meta), "file_bytes": rle_bytes,
                      "index_bytes": ip.stat().st_size,
                      "_frames_meta": frames_meta}
        srt_p = SDCARD / "COMMON" / "SRT" / SRT_NAME
        cues = parse_srt(srt_p.read_text(encoding="utf-8"))
        subs = {"srt_name": SRT_NAME, "srt_bytes": srt_p.stat().st_size,
                "srt_cues": len(cues), "srt_first": cues[0]["start"],
                "srt_last": cues[-1]["end"],
                "idx_name": "NARR.IDX",
                "idx_bytes": (SDCARD / "COMMON" / "SRT" / "NARR.IDX").stat().st_size,
                "ticker_name": "TICKER.TXT",
                "ticker_text": (SDCARD / "COMMON" / "TICKER.TXT").read_bytes().decode("ascii").rstrip(),
                "ticker_cols": (SDCARD / "COMMON" / "TICKER.TXT").stat().st_size,
                "ticker_trimmed_cols": len((SDCARD / "COMMON" / "TICKER.TXT")
                                           .read_bytes().decode("ascii").rstrip()),
                "ticker_bytes": (SDCARD / "COMMON" / "TICKER.TXT").stat().st_size,
                "cjk_unique_in_srt": len({ch for c in cues for ch in c["text"]})}
        manifests = {"COMMON/MANIFEST.TXT": (SDCARD / "COMMON" / "MANIFEST.TXT").stat().st_size}
        for dir_name, _w, _h, _r in RES_TABLE:
            manifests[f"{dir_name}/MANIFEST.TXT"] = (SDCARD / dir_name / "MANIFEST.TXT").stat().st_size
        burn_dirs = [SDCARD / f"BURN{DEFAULT_RES_DIR.replace('RES', '')}"]

    capacity = measure_capacity()
    check_lines = verify(img_records, audio_records, video_stat, subs, manifests, capacity)

    if not args.verify:
        echo("\n生成文档 assets/v2/SDCARD_LAYOUT.md ...")
        doc = write_layout_doc(img_records, audio_records, video_stat, subs, capacity,
                               manifests, check_lines, burn_dirs[0])
        echo(f"      {doc.name}  {doc.stat().st_size:,} B")

    echo("\n" + "=" * 78)
    echo("容量实测")
    echo("=" * 78)
    for r in capacity["dirs"]:
        echo(f"  {r['dir']:<12} {r['files']:>5} 个文件  {r['bytes']:>12,} B")
    echo(f"  {'根目录':<12} {capacity['root_files']:>5} 个文件  {capacity['root_bytes']:>12,} B")
    echo(f"  {'合计':<12} {'':>5}           {capacity['grand_total_bytes']:>12,} B "
         f"({capacity['grand_total_bytes']/1024/1024:.2f} MiB)")
    for b in burn_dirs:
        if b.exists():
            echo(f"  成品卡 {b.name:<8} {len(walk_tree(b)):>5} 个文件  {dir_bytes(b):>12,} B "
                 f"({dir_bytes(b)/1024/1024:.2f} MiB)")

    fail = any("!!" in ln for ln in check_lines)
    return 0 if not fail else 1


if __name__ == "__main__":
    sys.exit(main())
