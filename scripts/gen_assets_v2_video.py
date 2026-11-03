#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 assets/v2/masters/video/ 的视频相关母版：
  1. narration.wav —— 标准化为 48 kHz / 16 bit / 单声道
  2. narration.srt —— 与 narration.wav 对齐的字幕
  3. frames/       —— 抽帧样张（仅统计与样张，不导出整套帧序列）
  4. 带宽预算表     —— 单帧字节 / 目标帧率所需带宽 / SDRAM 可缓存帧数

不调用 ffmpeg：音频用标准库 wave，视频用 cv2。

关于 narration.wav 的"重采样"
-----------------------------
实测 work/fpga_intro_video/narration.wav 已经是 1 声道 / 2 字节 / 48000 Hz /
6,053,100 帧 / 126.10625 s —— **已经是 48 kHz 16 bit 单声道，无需重采样**。
本脚本仍做完整校验：若参数已符合，就原样复制并记录"无需重采样"；若不符合，
则用 numpy 线性插值重采样到 48 kHz（不依赖 ffmpeg/scipy）。这样脚本既诚实又通用。

关于字幕对齐
------------
work/fpga_intro_video/fpga_intro.srt 由 tts.py 在**同一进程、同一时间线**里生成：
每句旁白解码后 trim 静音、累加 LEAD/GAP/TAIL 得到起始时间，SRT 时间戳就取自这个
累加时间。因此 SRT 与 narration.wav 天然对齐。本脚本做的是**校验**：
  - 解析 SRT，检查时间戳单调递增、无重叠、末条不超出音频时长；
  - 归一化编号与时间格式（统一 CRLF->LF、补零位数），输出标准化副本；
  - 把校验结果写进 MANIFEST，供后续 OSD 字幕模块按时间轴取字幕。

关于视频
--------
work/fpga_intro_video/fpga_intro_640x480_60fps.mp4 是 H.264 压缩视频，
FPGA 端**没有解码能力**（captain 红线 1）。本脚本只做：
  - 用 cv2 读出真实时长/帧数/帧率（不是靠文件头猜）；
  - 抽取若干帧存为 PNG 样张，供架构看画面内容与色深；
  - 输出带宽预算表：单帧字节 / 目标帧率所需带宽 / SDRAM 可缓存帧数。
**不导出整套帧序列**（红线 3）：那要等 architect 的 PLAN.md 锁定帧率与色深后，
在 t4 阶段按 PLAN 执行。

带宽硬约束（captain 提供，用于表内对照）
--------------------------------------
  SD SPI 实用带宽 = 1.25 MB/s
  640x480 RGB888 全帧率 = 55.3 MB/s
  640x480 RGB565 全帧率 = 36.9 MB/s
两者都差几十倍 —— 这正是本表要让架构一眼看清的事实。

用法
----
    python scripts/gen_assets_v2_video.py
    python scripts/gen_assets_v2_video.py --check
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
import wave
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = REPO_ROOT / "assets" / "v2" / "masters" / "video"
SRC_DIR = REPO_ROOT.parent / "work" / "fpga_intro_video"
SRC_WAV = SRC_DIR / "narration.wav"
SRC_SRT = SRC_DIR / "fpga_intro.srt"
SRC_MP4 = SRC_DIR / "fpga_intro_640x480_60fps.mp4"

SR = 48000
SAMPWIDTH = 2
CHANNELS = 1

# 抽帧样张的时间点（秒）：覆盖片头/正文/结尾，用于看画面风格与色深
SAMPLE_TIMES = [1.0, 20.0, 40.0, 60.0, 80.0, 100.0, 120.0]

# SDRAM 容量（来自 docs/eram_sdram_reference.md §1：2M x 32 bit = 8 MiB）
SDRAM_BYTES = 8 * 1024 * 1024
# SD SPI 实用带宽（captain 红线 3 给出的硬约束）
SD_SPI_BYTES_PER_S = 1_250_000


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---- 音频 ---------------------------------------------------------------

def probe_wav(path: Path) -> dict:
    with wave.open(str(path), "rb") as w:
        return {"channels": w.getnchannels(), "sampwidth": w.getsampwidth(),
                "framerate": w.getframerate(), "frames": w.getnframes(),
                "duration_s": round(w.getnframes() / w.getframerate(), 6)}


def resample_linear(x: np.ndarray, src_sr: int, dst_sr: int) -> np.ndarray:
    """线性插值重采样（纯 numpy，不依赖 ffmpeg/scipy）。"""
    if src_sr == dst_sr:
        return x
    n_out = int(round(x.size * dst_sr / src_sr))
    pos = np.linspace(0.0, x.size - 1, n_out, dtype=np.float64)
    lo = np.floor(pos).astype(np.int64)
    hi = np.minimum(lo + 1, x.size - 1)
    frac = pos - lo
    return x[lo] * (1.0 - frac) + x[hi] * frac


def build_narration(out_dir: Path) -> dict:
    """把 narration.wav 标准化为 48 kHz/16 bit/单声道，写入 masters/video/。"""
    if not SRC_WAV.is_file():
        raise SystemExit(f"缺少源音频：{SRC_WAV}")
    src = probe_wav(SRC_WAV)
    print(f"  源 {SRC_WAV.name}: {src['channels']}ch/{src['sampwidth'] * 8}bit/"
          f"{src['framerate']}Hz  {src['frames']:,} 帧  {src['duration_s']:.5f} s")

    already_ok = (src["channels"] == CHANNELS and src["sampwidth"] == SAMPWIDTH
                  and src["framerate"] == SR)
    dst = out_dir / "narration.wav"
    out_dir.mkdir(parents=True, exist_ok=True)

    if already_ok:
        # 参数已符合：原样复制。不假装做了重采样。
        shutil.copyfile(SRC_WAV, dst)
        action = "无需重采样（源已是 48kHz/16bit/单声道），原样复制"
        print(f"  -> 源参数已符合目标规格，原样复制（不做无意义的重采样）")
    else:
        with wave.open(str(SRC_WAV), "rb") as w:
            raw = w.readframes(w.getnframes())
            sw = w.getsampwidth()
        if sw == 2:
            data = np.frombuffer(raw, dtype=np.int16).astype(np.float64) / 32768.0
        elif sw == 1:
            data = (np.frombuffer(raw, dtype=np.uint8).astype(np.float64) - 128.0) / 128.0
        elif sw == 4:
            data = np.frombuffer(raw, dtype=np.int32).astype(np.float64) / 2147483648.0
        else:
            raise SystemExit(f"不支持的采样位宽：{sw * 8} bit")
        if src["channels"] > 1:
            data = data.reshape(-1, src["channels"]).mean(axis=1)
        data = resample_linear(data, src["framerate"], SR)
        pcm = np.clip(data, -1.0, 1.0)
        pcm = (pcm * 32767.0).astype(np.int16)
        with wave.open(str(dst), "wb") as w:
            w.setnchannels(CHANNELS)
            w.setsampwidth(SAMPWIDTH)
            w.setframerate(SR)
            w.writeframes(pcm.tobytes())
        action = (f"重采样 {src['channels']}ch/{src['sampwidth'] * 8}bit/{src['framerate']}Hz"
                  f" -> {CHANNELS}ch/16bit/{SR}Hz（线性插值，numpy 实现）")
        print(f"  -> {action}")

    got = probe_wav(dst)
    print(f"  目标 {dst.name}: {got['channels']}ch/{got['sampwidth'] * 8}bit/"
          f"{got['framerate']}Hz  {got['frames']:,} 帧  {got['duration_s']:.5f} s  "
          f"{dst.stat().st_size:,} B")
    return {"src": src, "dst": got, "action": action, "path": dst}


# ---- 字幕 ---------------------------------------------------------------

_SRT_TIME = re.compile(
    r"(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})")


def parse_srt(path: Path) -> list[dict]:
    """解析 SRT，返回 [{index, start, end, text}]，start/end 单位为秒。"""
    text = path.read_text(encoding="utf-8-sig")
    blocks = re.split(r"\r?\n\r?\n", text.strip())
    cues = []
    for block in blocks:
        lines = [ln for ln in block.splitlines() if ln.strip() != ""]
        if not lines:
            continue
        ti = next((i for i, ln in enumerate(lines) if _SRT_TIME.search(ln)), None)
        if ti is None:
            continue
        m = _SRT_TIME.search(lines[ti])
        g = [int(x) for x in m.groups()]
        start = g[0] * 3600 + g[1] * 60 + g[2] + g[3] / (10 ** len(m.group(4)))
        end = g[4] * 3600 + g[5] * 60 + g[6] + g[7] / (10 ** len(m.group(8)))
        body = " ".join(ln.strip() for ln in lines[ti + 1:])
        cues.append({"index": len(cues) + 1, "start": round(start, 3),
                     "end": round(end, 3), "text": body})
    return cues


def srt_time(sec: float) -> str:
    ms = int(round(sec * 1000))
    return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d},{ms % 1000:03d}"


def build_srt(out_dir: Path, audio_dur: float) -> dict:
    """校验并标准化 SRT，输出到 masters/video/narration.srt。"""
    if not SRC_SRT.is_file():
        raise SystemExit(f"缺少源字幕：{SRC_SRT}")
    cues = parse_srt(SRC_SRT)
    if not cues:
        raise SystemExit(f"字幕解析为空：{SRC_SRT}")

    # 校验 1：时间戳单调递增
    monotonic = all(b["start"] >= a["start"] for a, b in zip(cues, cues[1:]))
    # 校验 2：无重叠（前一条的 end 不晚于后一条的 start）
    no_overlap = all(b["start"] >= a["end"] - 1e-6 for a, b in zip(cues, cues[1:]))
    # 校验 3：end > start
    positive = all(c["end"] > c["start"] for c in cues)
    # 校验 4：末条不超出音频时长
    within = cues[-1]["end"] <= audio_dur + 1e-6
    # 校验 5：文本非空
    nonempty = all(c["text"] for c in cues)

    print(f"  解析 {SRC_SRT.name}: {len(cues)} 条字幕，"
          f"首条 {cues[0]['start']:.3f}-{cues[0]['end']:.3f}s，"
          f"末条 {cues[-1]['start']:.3f}-{cues[-1]['end']:.3f}s")
    print(f"  校验：单调递增={monotonic} 无重叠={no_overlap} end>start={positive} "
          f"不超音频({audio_dur:.3f}s)={within} 文本非空={nonempty}")

    # 标准化输出：统一 LF、编号从 1 连续、时间格式补零
    out_dir.mkdir(parents=True, exist_ok=True)
    dst = out_dir / "narration.srt"
    lines = []
    for i, c in enumerate(cues, 1):
        lines.append(str(i))
        lines.append(f"{srt_time(c['start'])} --> {srt_time(c['end'])}")
        lines.append(c["text"])
        lines.append("")
    dst.write_text("\n".join(lines), encoding="utf-8")
    print(f"  -> {dst.name}  {dst.stat().st_size:,} B（UTF-8, LF）")

    total_speech = sum(c["end"] - c["start"] for c in cues)
    return {
        "cues": cues, "count": len(cues), "path": dst,
        "checks": {"monotonic": monotonic, "no_overlap": no_overlap,
                   "positive": positive, "within_audio": within,
                   "nonempty": nonempty},
        "speech_total_s": round(total_speech, 3),
        "first_start_s": cues[0]["start"], "last_end_s": cues[-1]["end"],
    }


# ---- 视频 ---------------------------------------------------------------

def build_video_stats(out_dir: Path) -> dict:
    """用 cv2 读 mp4 统计真实时长/帧数/帧率，抽帧样张，输出带宽预算表。"""
    import cv2
    if not SRC_MP4.is_file():
        raise SystemExit(f"缺少源视频：{SRC_MP4}")

    cap = cv2.VideoCapture(str(SRC_MP4))
    if not cap.isOpened():
        raise SystemExit(f"cv2 无法打开：{SRC_MP4}")
    fps = float(cap.get(cv2.CAP_PROP_FPS))
    frame_count_hdr = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fourcc = int(cap.get(cv2.CAP_PROP_FOURCC))

    # 真实解码一遍，得到实际可解码帧数（比读文件头更可信）
    decoded = 0
    while True:
        ok, _ = cap.read()
        if not ok:
            break
        decoded += 1
    cap.release()

    duration = decoded / fps if fps > 0 else 0.0
    print(f"  容器 {SRC_MP4.name}: {SRC_MP4.stat().st_size:,} B")
    print(f"  cv2 读出头信息: {width}x{height}  fps={fps:g}  "
          f"头标帧数={frame_count_hdr}  实际解码={decoded}  "
          f"时长={duration:.3f} s  FOURCC={fourcc}")

    # 抽帧样张
    frames_dir = out_dir / "frames"
    frames_dir.mkdir(parents=True, exist_ok=True)
    samples = []
    cap = cv2.VideoCapture(str(SRC_MP4))
    for t in SAMPLE_TIMES:
        if t > duration:
            continue
        cap.set(cv2.CAP_PROP_POS_MSEC, t * 1000.0)
        ok, frame = cap.read()
        if not ok or frame is None:
            print(f"  （跳过 t={t}s：读取失败）")
            continue
        idx = int(round(t * fps))
        path = frames_dir / f"frame_{idx:05d}_t{t:06.2f}s.png"
        cv2.imwrite(str(path), frame)
        samples.append({"t_s": t, "frame_index": idx, "path": path,
                        "size": (frame.shape[1], frame.shape[0])})
        print(f"  抽帧 t={t:6.2f}s -> {path.name}  {path.stat().st_size:,} B")
    cap.release()

    return {"fps": fps, "width": width, "height": height, "fourcc": fourcc,
            "frame_count_header": frame_count_hdr, "frame_count_decoded": decoded,
            "duration_s": round(duration, 4), "src_bytes": SRC_MP4.stat().st_size,
            "samples": samples}


def bandwidth_table(width: int, height: int) -> dict:
    """单帧字节 / 目标帧率所需带宽 / SDRAM 可缓存帧数。

    色深取三种工程上真实可选的：
      RGB888 (24bpp) —— 最清晰，SD 卡 BMP 现在就是这种
      RGB565 (16bpp) —— 显示管线双缓冲当前用的格式
      RGB332 (8bpp)  —— 极限压缩，颜色数 256，画面会明显失真
    帧率取 5 档：1/5/10/15/30 fps（FPGA 从 SD 卡顺序读的实际可用范围）。
    """
    pixels = width * height
    depths = [("RGB888", 24), ("RGB565", 16), ("RGB332", 8)]
    rates = [1, 5, 10, 15, 30]
    rows = []
    for name, bpp in depths:
        frame_bytes = pixels * bpp // 8
        for r in rates:
            need = frame_bytes * r
            rows.append({
                "pixfmt": name, "bpp": bpp,
                "frame_bytes": frame_bytes,
                "frame_kib": round(frame_bytes / 1024.0, 1),
                "fps": r,
                "bandwidth_Bps": need,
                "bandwidth_MBps": round(need / 1e6, 3),
                "sd_ratio": round(need / SD_SPI_BYTES_PER_S, 2),
                "sd_ok": need <= SD_SPI_BYTES_PER_S,
                "sdram_frames": SDRAM_BYTES // frame_bytes,
                "sdram_used_pct": round(frame_bytes / SDRAM_BYTES * 100.0, 2),
            })
    return {"pixels": pixels, "depths": depths, "rates": rates, "rows": rows,
            "sdram_bytes": SDRAM_BYTES, "sd_spi_Bps": SD_SPI_BYTES_PER_S}


def print_bandwidth_table(tbl: dict):
    w = tbl["rows"]
    print(f"\n  单帧像素 {tbl['pixels']:,}   SDRAM {tbl['sdram_bytes']:,} B "
          f"({tbl['sdram_bytes'] / 1024 / 1024:.0f} MiB)   "
          f"SD SPI 实用带宽 {tbl['sd_spi_Bps']:,} B/s ({tbl['sd_spi_Bps'] / 1e6:.2f} MB/s)")
    print(f"  {'色深':8s} {'bpp':>3s} {'单帧字节':>10s} {'帧率':>4s} "
          f"{'所需带宽MB/s':>13s} {'/SD带宽':>8s} {'可行':>4s} {'SDRAM可存帧':>11s}")
    print("  " + "-" * 76)
    for r in w:
        print(f"  {r['pixfmt']:8s} {r['bpp']:3d} {r['frame_bytes']:10,} {r['fps']:4d} "
              f"{r['bandwidth_MBps']:13.3f} {r['sd_ratio']:7.2f}x "
              f"{'OK' if r['sd_ok'] else 'NO':>4s} {r['sdram_frames']:11d}")
    ok = [r for r in w if r["sd_ok"]]
    print(f"\n  SD SPI 带宽内可行的组合：{len(ok)} / {len(w)}")
    if ok:
        best = max(ok, key=lambda r: (r["fps"], -r["bpp"]))
        print(f"  最高帧率的可行组合：{best['pixfmt']} @ {best['fps']} fps "
              f"({best['bandwidth_MBps']:.3f} MB/s = SD 带宽的 {best['sd_ratio']:.2f}x)，"
              f"SDRAM 可缓存 {best['sdram_frames']} 帧")


def playback_duty_table(tbl: dict) -> list[dict]:
    """SDRAM 预载 + 边播边填 的占空比分析。

    为什么需要这张表
    ----------------
    上面的带宽表说明：640x480 下 SD SPI 只够 1 fps。但视频不能只有 1 fps。
    工程上唯一的出路是**预载到 SDRAM 再播放**：先填满 SDRAM，然后一边播放
    （消耗缓存帧）一边从 SD 卡补帧。SDRAM 只有 8 MiB，能存的帧数很有限
    （RGB565 13 帧、RGB332 27 帧），于是播放必然是"播放-卡顿-再播放"的
    周期性过程。这张表把它量化成三个数：
      play_s   —— 一箱缓存能连续播多久
      fill_s   —— 播完后重新填满要等多久
      duty     —— 有效播放时间占空比 = play_s / (play_s + fill_s)
    架构可以据此判断：哪些组合"勉强能看"，哪些"完全不可行"。
    这是 t3 只做统计、不导出帧序列的前提下，能给架构的最有价值的信息。
    """
    rows = []
    for pixfmt, bpp in tbl["depths"]:
        frame_bytes = tbl["pixels"] * bpp // 8
        frames = SDRAM_BYTES // frame_bytes
        # 留一帧做双缓冲切换开销
        usable = max(frames - 1, 1)
        for fps in tbl["rates"]:
            play_s = usable / fps
            fill_s = usable * frame_bytes / SD_SPI_BYTES_PER_S
            duty = play_s / (play_s + fill_s)
            rows.append({
                "pixfmt": pixfmt, "bpp": bpp, "fps": fps,
                "cached_frames": usable,
                "play_s": round(play_s, 2),
                "fill_s": round(fill_s, 2),
                "duty_pct": round(duty * 100.0, 1),
                "verdict": ("流畅" if duty >= 0.9 else
                            "可接受" if duty >= 0.5 else
                            "明显卡顿" if duty >= 0.2 else "不可行"),
            })
    return rows


def print_playback_duty(rows: list[dict]):
    print(f"\n  SDRAM 预载 + 边播边填 的占空比分析（SDRAM 8 MiB，SD SPI 1.25 MB/s）：")
    print(f"  {'色深':8s} {'帧率':>4s} {'可缓存帧':>8s} {'可连播s':>8s} "
          f"{'重填s':>7s} {'占空比':>7s} {'评价':>8s}")
    print("  " + "-" * 62)
    for r in rows:
        print(f"  {r['pixfmt']:8s} {r['fps']:4d} {r['cached_frames']:8d} "
              f"{r['play_s']:8.2f} {r['fill_s']:7.2f} "
              f"{r['duty_pct']:6.1f}% {r['verdict']:>8s}")
    ok = [r for r in rows if r["duty_pct"] >= 50.0]
    if ok:
        best = max(ok, key=lambda r: (r["fps"], -r["bpp"]))
        print(f"\n  占空比>=50% 的最佳组合：{best['pixfmt']} @ {best['fps']} fps "
              f"（连播 {best['play_s']}s / 重填 {best['fill_s']}s，占空比 {best['duty_pct']}%）")
    else:
        print(f"\n  没有任何组合能达到 50% 占空比 —— 640x480 全帧视频从 SD 卡播放不可行。")


# ---- RLE 可压缩性统计（captain 实测的独立复算） -----------------------------

RLE_MAGIC = b"CVRLE"          # 自定义 .RLE 帧头魔数（与 t4 导出格式一致）
RLE_RUN_MAX = 256             # run_len 8 bit，0 表示 256


def rle_encode_rgb565(pixels_bgr: np.ndarray, run_bits: int = 8) -> tuple[int, int]:
    """把一帧 BGR 像素量化为 RGB565 后做逐行游程编码。

    run 值域受 run_bits 限制（run_bits=8 时每条目 3 B：rgb565 2 B + run 1 B；
    run_bits=16 时每条目 4 B）。run_len 用值 0 表示 256（8 bit 档）或 65536
    （16 bit 档，实际用不到，仅为完整性）。返回 (编码字节数, 游程条数)。
    """
    b = pixels_bgr.reshape(-1, 3).astype(np.uint16)
    r5 = (b[:, 2] >> 3) << 11
    g6 = (b[:, 1] >> 2) << 5
    b5 = (b[:, 0] >> 3)
    px = r5 | g6 | b5
    n = px.size
    change = np.empty(n, dtype=bool)
    change[0] = True
    np.not_equal(px[1:], px[:-1], out=change[1:])
    run_starts = np.flatnonzero(change)
    run_vals = px[run_starts]
    run_lens = np.diff(np.append(run_starts, n))
    run_max = 1 << run_bits
    # 长游程拆分成多条（每条最多 run_max 个像素）
    runs = int(((run_lens + run_max - 1) // run_max).sum())
    # 每条目字节数 = 2(rgb565) + run_bits//8
    return runs * (2 + run_bits // 8), runs


def rle_stats(sample_stride: int = 60) -> dict:
    """对全片按固定间隔抽帧做 RLE 压缩性统计（本任务自己解码，独立复算）。

    为什么 stride=60：源视频 60 fps，每 60 帧抽 1 帧 = 1 秒 1 帧，
    126 s 全片覆盖，同时把解码量压到 ~127 帧，脚本几秒内跑完。
    输出两种 run 位宽的统计（均值/最小/最大/p95）与带宽换算，
    供架构判断「RLE 压缩后视频播放可行帧率」。
    """
    import cv2
    cap = cv2.VideoCapture(str(SRC_MP4))
    if not cap.isOpened():
        raise SystemExit(f"cv2 无法打开：{SRC_MP4}")
    fps = float(cap.get(cv2.CAP_PROP_FPS))
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    stride = max(1, int(round(fps))) * 1     # 每秒 1 帧（60 fps 源 = stride 60）
    # 上面写法依赖 fps 恰为整数；这里按"每秒 1 帧"明确取 stride=round(fps)
    stride = max(1, int(round(fps)))
    sizes = {8: [], 16: []}
    runs = {8: [], 16: []}
    idx = 0
    sampled = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if idx % stride == 0:
            for bits in (8, 16):
                nb, nr = rle_encode_rgb565(frame, run_bits=bits)
                sizes[bits].append(nb)
                runs[bits].append(nr)
            sampled += 1
        idx += 1
    cap.release()

    def stat(arr: list[int]) -> dict:
        a = np.asarray(arr, dtype=np.float64)
        return {"mean": round(float(a.mean()), 1),
                "min": int(a.min()), "max": int(a.max()),
                "p95": round(float(np.percentile(a, 95)), 1)}

    out = {"sample_stride_frames": stride, "sampled_frames": sampled,
           "total_frames": total, "quantization": "RGB565",
           "row_order": "逐行扫描（横向游程）",
           "note": ("本节为 t3 用 cv2 独立解码后的复算值（未采信外部数字）。"
                    "上游未压缩带宽表的前提是逐字节原样传输；RLE 表的前提是"
                    "游程压缩后按条目传输 —— 两张表前提不同，RLE 表为最终选型依据。"),
           "encodings": {}}
    for bits in (8, 16):
        st = stat(sizes[bits])
        entry = {"run_bits": bits,
                 "bytes_per_run": 2 + bits // 8,
                 "frame_bytes": st,
                 "runs_per_frame": stat(runs[bits])}
        # 带宽换算：mean / worst(max) 两档
        for label, v in (("mean", st["mean"]), ("worst", float(st["max"]))):
            for r in (1, 2, 5, 8):
                bw = v * r
                entry[f"bw_{label}_fps{r}_MBps"] = round(bw / 1e6, 3)
                entry[f"bw_{label}_fps{r}_sd_ratio"] = round(bw / SD_SPI_BYTES_PER_S, 2)
        out["encodings"][f"rle{bits}"] = entry
    return out


def print_rle_stats(rs: dict):
    print(f"\n  RLE 可压缩性统计（RGB565 量化，每 {rs['sample_stride_frames']} 帧抽 1 帧，"
          f"共 {rs['sampled_frames']} 帧）：")
    print(f"  {'编码':10s} {'每条目B':>7s} {'均值B/帧':>10s} {'最小':>8s} {'最大':>8s} "
          f"{'p95':>8s}")
    print("  " + "-" * 60)
    for key, e in rs["encodings"].items():
        st = e["frame_bytes"]
        print(f"  {key:10s} {e['bytes_per_run']:7d} {st['mean']:10,.0f} "
              f"{st['min']:8,d} {st['max']:8,d} {st['p95']:8,.0f}")
    print(f"\n  RLE3（3 B/条目）带宽账 vs SD SPI 1.25 MB/s：")
    e = rs["encodings"]["rle8"]
    for r in (1, 2, 5, 8):
        m = e[f"bw_mean_fps{r}_MBps"]
        w = e[f"bw_worst_fps{r}_MBps"]
        print(f"    @{r}fps: mean {m:.3f} MB/s ({e[f'bw_mean_fps{r}_sd_ratio']:.2f}x)   "
              f"worst {w:.3f} MB/s ({e[f'bw_worst_fps{r}_sd_ratio']:.2f}x)")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="只校验已有产物")
    ap.add_argument("--out", type=Path, default=OUT_DIR)
    args = ap.parse_args()
    out: Path = args.out
    out.mkdir(parents=True, exist_ok=True)

    print("[1/4] 旁白音频标准化")
    audio = build_narration(out)

    print("\n[2/4] 字幕对齐与标准化")
    srt = build_srt(out, audio["dst"]["duration_s"])

    print("\n[3/4] 视频统计与抽帧样张")
    video = build_video_stats(out)

    print("\n[4/5] 带宽预算表")
    tbl = bandwidth_table(video["width"], video["height"])
    print_bandwidth_table(tbl)
    duty = playback_duty_table(tbl)
    print_playback_duty(duty)

    print("\n[5/5] RLE 可压缩性统计（独立复算）")
    rs = rle_stats()
    print_rle_stats(rs)

    # 汇总
    summary = {
        "narration_wav": {
            "path": str(audio["path"].relative_to(REPO_ROOT)),
            "action": audio["action"],
            "channels": audio["dst"]["channels"],
            "bits": audio["dst"]["sampwidth"] * 8,
            "sample_rate": audio["dst"]["framerate"],
            "frames": audio["dst"]["frames"],
            "duration_s": audio["dst"]["duration_s"],
            "bytes": audio["path"].stat().st_size,
            "sha256": sha256_of(audio["path"]),
        },
        "narration_srt": {
            "path": str(srt["path"].relative_to(REPO_ROOT)),
            "count": srt["count"],
            "checks": srt["checks"],
            "speech_total_s": srt["speech_total_s"],
            "first_start_s": srt["first_start_s"],
            "last_end_s": srt["last_end_s"],
            "bytes": srt["path"].stat().st_size,
            "sha256": sha256_of(srt["path"]),
        },
        "video_source": {
            "path": str(SRC_MP4.relative_to(REPO_ROOT.parent)),
            "bytes": video["src_bytes"],
            "width": video["width"], "height": video["height"],
            "fps": video["fps"],
            "frame_count_header": video["frame_count_header"],
            "frame_count_decoded": video["frame_count_decoded"],
            "duration_s": video["duration_s"],
            "note": "H.264 压缩视频，FPGA 端无解码能力，仅作素材预览与统计来源，不可作 SD 卡播放源",
        },
        "frames_samples": [
            {"t_s": s["t_s"], "frame_index": s["frame_index"],
             "file": s["path"].name,
             "bytes": s["path"].stat().st_size,
             "size": list(s["size"])}
            for s in video["samples"]
        ],
        "bandwidth_table": {
            "pixels": tbl["pixels"],
            "sdram_bytes": tbl["sdram_bytes"],
            "sd_spi_Bps": tbl["sd_spi_Bps"],
            "rows": tbl["rows"],
        },
        "playback_duty": {
            "note": "SDRAM 预载+边播边填：连播时长 / 重填时长 / 占空比",
            "rows": duty,
        },
        "rle_stats": rs,
    }
    js = out / "video_stats.json"
    js.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n统计已写入 {js}  ({js.stat().st_size:,} B)")

    # 自检：用 wave / cv2 / 文本重新打开每个产物
    print("\n[自检] 重新打开校验：")
    all_ok = True
    with wave.open(str(out / "narration.wav"), "rb") as w:
        ok = (w.getnchannels() == CHANNELS and w.getsampwidth() == SAMPWIDTH
              and w.getframerate() == SR and w.getnframes() > 0)
    all_ok &= ok
    print(f"  [{'OK ' if ok else 'BAD'}] narration.wav  {CHANNELS}ch/16bit/{SR}Hz")

    srt_txt = (out / "narration.srt").read_text(encoding="utf-8")
    cues2 = parse_srt(out / "narration.srt")
    ok = len(cues2) == srt["count"] and all(c["text"] for c in cues2)
    all_ok &= ok
    print(f"  [{'OK ' if ok else 'BAD'}] narration.srt  重新解析得 {len(cues2)} 条"
          f"（原 {srt['count']} 条）")

    import cv2
    bad = []
    for s in video["samples"]:
        im = cv2.imread(str(s["path"]))
        if im is None or im.shape[1] != video["width"] or im.shape[0] != video["height"]:
            bad.append(s["path"].name)
    ok = not bad
    all_ok &= ok
    print(f"  [{'OK ' if ok else 'BAD'}] frames/  用 cv2 重新读取 {len(video['samples'])} 张样张"
          f"{'，全部尺寸正确' if ok else '，异常：' + ', '.join(bad)}")

    ok = js.is_file() and json.loads(js.read_text(encoding="utf-8"))["bandwidth_table"]["rows"]
    all_ok &= bool(ok)
    print(f"  [{'OK ' if ok else 'BAD'}] video_stats.json  可被 json 解析且含带宽表")

    print(f"\n[自检] {'全部通过' if all_ok else '存在失败项'}")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
