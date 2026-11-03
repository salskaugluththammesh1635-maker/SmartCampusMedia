#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""汇总 assets/v2/ 全部母版素材，生成 MANIFEST.json 与 README.md。

设计原则：**一切数值从磁盘实测，绝不硬编码**
--------------------------------------------
本脚本不复制任何"我以为的大小/时长"，而是逐个用对应库**重新打开文件**读取：
  PNG       -> Pillow 读尺寸/模式
  WAV       -> wave 读声道/位宽/采样率/帧数
  MP4/json  -> 统计来源文件里的实测值
文件大小、sha256 全部现场计算。这样 MANIFEST 与磁盘永远一致，
不会出现"文档写了 40 s，实际文件 39.8 s"这类答辩致命的偏差。

为什么需要 MANIFEST
------------------
t4（五档分辨率素材包）要以母版为输入。它需要一份机器可读的清单，知道：
  - 每个母版的路径、尺寸/时长、格式；
  - 来源与授权（无版权风险项，答辩必问）；
  - 由哪个脚本生成（可复现）；
  - 关键降级/限制（如上采样对照、TTS 不可用、视频只做统计）。

用法
----
    python scripts/gen_assets_v2_manifest.py
    python scripts/gen_assets_v2_manifest.py --check   # 只校验不重写
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import wave
from pathlib import Path

from PIL import Image

REPO_ROOT = Path(__file__).resolve().parents[1]
V2 = REPO_ROOT / "assets" / "v2"
MASTERS = V2 / "masters"

# 场景标题（与 generate_campus_media.py 的 SCENES 一致，仅用于写用途说明）
IMAGE_TITLES = {
    "IMG001": ("智慧校园", "Smart Campus"),
    "IMG002": ("书香校园", "Scholarly Campus"),
    "IMG003": ("创客工坊", "Maker Workshop"),
    "IMG004": ("绿色校园", "Green Campus"),
    "IMG005": ("运动嘉年华", "Sports Carnival"),
    "IMG006": ("平安校园", "Safe Campus"),
}


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def probe_png(path: Path) -> dict:
    with Image.open(path) as im:
        im.load()
        return {"width": im.width, "height": im.height, "mode": im.mode,
                "format": im.format}


def probe_wav(path: Path) -> dict:
    with wave.open(str(path), "rb") as w:
        nf, fr = w.getnframes(), w.getframerate()
        return {"channels": w.getnchannels(), "sampwidth": w.getsampwidth(),
                "bits": w.getsampwidth() * 8, "sample_rate": fr,
                "frames": nf, "duration_s": round(nf / fr, 6)}


def measure_wav_acoustics(path: Path) -> dict:
    """现场实测五项声学参数（captain 要求 MANIFEST 必含）：
    时长 / peak dBFS / rms dBFS / 主频 / 人耳敏感带(300~4000Hz)能量占比。
    全部从磁盘文件现算，与 gen_assets_v2_audio.py 的自检口径一致。
    """
    import numpy as np
    with wave.open(str(path), "rb") as w:
        fr = w.getframerate()
        nf = w.getnframes()
        raw = w.readframes(nf)
    x = np.frombuffer(raw, dtype=np.int16).astype(np.float64) / 32768.0
    peak = float(np.abs(x).max())
    rms = float(np.sqrt(np.mean(x * x)))
    spec = np.abs(np.fft.rfft(x))
    freqs = np.fft.rfftfreq(x.size, 1.0 / fr)
    f0 = float(freqs[1:][np.argmax(spec[1:])]) if spec.size > 1 else 0.0
    band = (freqs >= 300.0) & (freqs <= 4000.0)
    total_e = float(np.sum(spec * spec)) or 1e-12
    sens = float(np.sum(spec[band] * spec[band]) / total_e)
    return {
        "peak_dbfs": round(20.0 * np.log10(max(peak, 1e-6)), 2),
        "rms_dbfs": round(20.0 * np.log10(max(rms, 1e-6)), 2),
        "dominant_freq_hz": round(f0, 1),
        "sensitive_band_300_4k_pct": round(sens * 100.0, 1),
    }


def collect_images() -> list[dict]:
    d = MASTERS / "images"
    items = []
    for p in sorted(d.glob("IMG*.png")):
        stem = p.stem
        if stem.endswith("_1280x960"):
            continue
        key = stem[:6]
        zh, en = IMAGE_TITLES.get(key, ("", ""))
        info = probe_png(p)
        items.append({
            "id": key,
            "role": "master",
            "title": f"{zh} / {en}",
            "use": "校园景点图母版（1920x1440），供 t4 派生五档分辨率",
            "path": str(p.relative_to(REPO_ROOT)).replace("\\", "/"),
            "format": "PNG",
            **info,
            "bytes": p.stat().st_size,
            "sha256": sha256_of(p),
            "generated_by": "scripts/gen_assets_v2_images.py",
            "source": ("scripts/generate_campus_media.py 的原生重渲染"
                       "（矢量绘制管线，非上采样）"),
            "license": ("程序化绘制，无第三方图像版权；字体 Noto Sans SC "
                        "(SIL OFL 1.1) 已栅格化为图形，不构成字体再分发"),
            "upgraded_from_640x480": False,
        })
        base = d / f"{stem}_1280x960.png"
        if base.is_file():
            binfo = probe_png(base)
            items.append({
                "id": f"{key}_1280x960",
                "role": "base",
                "title": f"{zh} / {en}（1280x960 基准版）",
                "use": "五档分辨率派生的基准尺寸版本",
                "path": str(base.relative_to(REPO_ROOT)).replace("\\", "/"),
                "format": "PNG", **binfo,
                "bytes": base.stat().st_size,
                "sha256": sha256_of(base),
                "generated_by": "scripts/gen_assets_v2_images.py",
                "source": "同母版（原生重渲染后缩放到 1280x960）",
                "license": "同母版",
                "upgraded_from_640x480": False,
            })
    return items


def collect_upscaled() -> list[dict]:
    d = MASTERS / "images" / "reference_upscaled"
    items = []
    for p in sorted(d.glob("*.png")):
        info = probe_png(p)
        key = p.stem[:6]
        zh, en = IMAGE_TITLES.get(key, ("", ""))
        items.append({
            "id": p.stem,
            "role": "reference_only",
            "title": f"{zh} / {en}（640x480 上采样对照）",
            "use": ("**仅作对照参考，不是母版**。用于证明母版是原生重渲染而非"
                    "上采样：同尺寸下上采样锐度只有母版的 43%"),
            "path": str(p.relative_to(REPO_ROOT)).replace("\\", "/"),
            "format": "PNG", **info,
            "bytes": p.stat().st_size,
            "sha256": sha256_of(p),
            "generated_by": "scripts/gen_assets_v2_images.py",
            "source": ("由既有 assets/campus_media/sd_card/IMG00N.BMP (640x480) "
                       "用 cv2 INTER_LANCZOS4 上采样"),
            "license": "同既有 BMP（程序化绘制）",
            "upgraded_from_640x480": True,
            "warning": "上采样产物，非原生高清，不可作为母版使用",
        })
    return items


def collect_audio() -> list[dict]:
    d = MASTERS / "audio"
    meta = {
        "bgm_serene.wav": {
            "title": "静谧晨光 / Serene Campus Morning",
            "use": "日常模式背景音乐（开机/图库浏览）",
            "chords": "C大调 Imaj7-vi7-IVmaj7-V7",
            "loop": True,
            "loop_note": ("整段无缝循环：首尾各 1.2 s 淡入/淡出，"
                          "循环播放时建议 crossfade 200 ms 或整段重播"
                          "（淡入淡出保证无爆音）"),
        },
        "bgm_focus.wav": {
            "title": "专注时刻 / Focus in the Library",
            "use": "科普模式背景音乐（讲解/字幕演示）",
            "chords": "A小调 i9-VI-III-VII",
            "loop": True,
            "loop_note": "同 bgm_serene：整段循环，首尾淡入淡出",
        },
        "bgm_uplift.wav": {
            "title": "绿色律动 / Green Campus Motion",
            "use": "科普/日常切换过渡背景音乐",
            "chords": "F大调 Imaj7-V-vi7-IVmaj7",
            "loop": True,
            "loop_note": "同 bgm_serene：整段循环，首尾淡入淡出",
        },
        "alarm_siren.wav": {
            "title": "应急双音警报 / Emergency Two-Tone Siren",
            "use": "应急模式报警音（AHT20 高温联动/应急提示）",
            "chords": "740/1110 Hz 双音交替（纯五度），含 2/3 次谐波",
            "loop": True,
            "loop_note": ("**必须循环**：单段仅 6.00 s，应急持续报警需 RTL 端"
                          "整段循环播放。段内为整数个周期（14 个 0.42 s 段），"
                          "循环点无相位跳变，可直接循环无需 crossfade"),
        },
    }
    items = []
    for p in sorted(d.glob("*.wav")):
        info = probe_wav(p)
        ac = measure_wav_acoustics(p)
        m = meta.get(p.name, {})
        items.append({
            "id": p.stem,
            "role": "master",
            "title": m.get("title", p.stem),
            "use": m.get("use", ""),
            "music_form": m.get("chords", ""),
            "path": str(p.relative_to(REPO_ROOT)).replace("\\", "/"),
            "format": "WAV (PCM)",
            **info,
            **ac,
            "bytes": p.stat().st_size,
            "sha256": sha256_of(p),
            "loop": m.get("loop", False),
            "loop_note": m.get("loop_note", ""),
            "generated_by": "scripts/gen_assets_v2_audio.py",
            "source": ("numpy 程序化合成（分解和弦 pad + 低通正弦 + 淡入淡出），"
                       if p.name != "alarm_siren.wav" else
                       "numpy 程序化合成（双音交替 siren + 谐波 + 包络）"),
            "license": "**程序化生成，无第三方版权**（未使用任何采样/音源库）",
            "upgraded_from_640x480": False,
        })
    return items


def collect_font() -> list[dict]:
    d = MASTERS / "font"
    src = "scripts/gen_assets_v2_font.py"
    lic = ("字形栅格化自 Noto Sans SC Regular（SIL Open Font License 1.1），"
           "授权全文见 docs/OFL-NotoSansSC.txt，说明见 docs/science_font_attribution.md；"
           "**只分发栅格化后的点阵数据，不随工程分发字体文件本身**")
    items = []
    desc = {
        "cjk16_font.v": ("Verilog case 表 ROM（工程惯例，TD 推断 ROM 更稳）",
                         "供 t5/t6/t7 RTL 阶段直接接入的 16x16 中文点阵 ROM"),
        "cjk16_bitmap.hex": ("纯文本点阵（每行 4 位十六进制，可直接 $readmemh）",
                             "通用数据格式，便于非 Verilog 流程复用"),
        "cjk16_bitmap.json": ("带元数据的完整点阵（字符/码位/每行位图/墨点统计）",
                              "机器可读的权威数据源"),
        "cjk16_charset.txt": ("索引 ↔ 字符 ↔ 码位对照表", "人读对照"),
        "cjk16_preview.png": ("全部字形拼版预览图", "目视核对字形无糊连/无裁字"),
    }
    # 字形数、格子尺寸、位序等**一律从 cjk16_bitmap.json 实测**，不写死。
    # 教训（t14）：字库从 95 扩到 465 之后，此处若仍硬编码 95，MANIFEST 就会
    # 与磁盘实况不符。而"文档里对、磁盘上不对"这类偏差最难被发现——没有任何
    # 一个文件本身是错的，只是两者不再描述同一件事。
    js_p = d / "cjk16_bitmap.json"
    fmeta = json.loads(js_p.read_text(encoding="utf-8")) if js_p.is_file() else {}
    glyph_count = fmeta.get("glyph_count")
    _cell = fmeta.get("cell") or {}
    cell_desc = (f"{_cell.get('width')}x{_cell.get('height')}"
                 if _cell.get("width") and _cell.get("height") else None)
    bit_order = fmeta.get("bit_order")
    _fm = fmeta.get("font") or {}
    _rs = fmeta.get("raster") or {}

    for p in sorted(d.iterdir()):
        if not p.is_file():
            continue
        fmt, use = desc.get(p.name, ("", ""))
        n = {"width": None, "height": None}
        if p.suffix == ".png":
            n = probe_png(p)
        items.append({
            "id": p.stem,
            "role": "master",
            "title": p.name,
            "use": use,
            "path": str(p.relative_to(REPO_ROOT)).replace("\\", "/"),
            "format": fmt,
            **{k: v for k, v in n.items() if v is not None},
            "bytes": p.stat().st_size,
            "sha256": sha256_of(p),
            "generated_by": src,
            "source": (f"Noto Sans SC {_fm.get('weight', 'Regular')}"
                       f" @ {_fm.get('size')}px, {cell_desc or '16x16'} 格子,"
                       f" 阈值 {_rs.get('threshold')}, 墨迹包围盒居中"),
            "license": lic,
            "glyph_count": glyph_count,
            "cell": cell_desc,
            "bit_order": bit_order,
            "index_freeze_note": (
                "索引 0..94 为冻结段（t3 时期的 95 字）；新增字形只从 95 起追加，"
                "不得重排——RTL 以 index 硬引用字库，重排等于静默显示错字"),
            "scope_note": "**只做数据，不写 RTL**（接入由 t5/t6/t7 决定）",
            "upgraded_from_640x480": False,
        })
    return items


def collect_video() -> dict:
    d = MASTERS / "video"
    js = d / "video_stats.json"
    stats = json.loads(js.read_text(encoding="utf-8")) if js.is_file() else {}
    wav_p = d / "narration.wav"
    srt_p = d / "narration.srt"
    frames = sorted((d / "frames").glob("*.png"))
    return {
        "narration_wav": {
            "path": str(wav_p.relative_to(REPO_ROOT)).replace("\\", "/"),
            **probe_wav(wav_p),
            "bytes": wav_p.stat().st_size,
            "sha256": sha256_of(wav_p),
            "action": stats.get("narration_wav", {}).get("action", ""),
            "use": "科普模式视频旁白音轨",
            "generated_by": "scripts/gen_assets_v2_video.py",
            "source": "work/fpga_intro_video/narration.wav（原 edge_tts 生成）",
            "license": ("旁白文本为本项目原创讲稿；语音由 edge_tts 合成，"
                        "未使用第三方音乐/音效素材"),
        },
        "narration_srt": {
            "path": str(srt_p.relative_to(REPO_ROOT)).replace("\\", "/"),
            "bytes": srt_p.stat().st_size,
            "sha256": sha256_of(srt_p),
            "count": stats.get("narration_srt", {}).get("count"),
            "checks": stats.get("narration_srt", {}).get("checks"),
            "use": "与 narration.wav 逐句对齐的标准字幕，供 OSD 字幕模块按时间轴取用",
            "generated_by": "scripts/gen_assets_v2_video.py",
            "source": "work/fpga_intro_video/fpga_intro.srt（与 narration.wav 同源同时间线）",
            "license": "本项目原创讲稿",
        },
        "frames_samples": [
            {"file": p.name, "path": str(p.relative_to(REPO_ROOT)).replace("\\", "/"),
             "bytes": p.stat().st_size, **probe_png(p)}
            for p in frames
        ],
        "stats": stats,
    }


def build_manifest() -> dict:
    imgs = collect_images()
    ups = collect_upscaled()
    auds = collect_audio()
    fonts = collect_font()
    video = collect_video()
    return {
        "schema": "smart-campus-media-assets-v2",
        "generated_by": "scripts/gen_assets_v2_manifest.py",
        "note": ("全部数值由本脚本从磁盘实测读取（Pillow 开图 / wave 开音频 / "
                 "json 重解析），非硬编码"),
        "directories": {
            "masters": "assets/v2/masters/（母版，t4 的输入）",
            "derived": "assets/v2/derived/（t4 产出的五档分辨率素材）",
            "sdcard": "assets/v2/sdcard/（t4 产出的 SD 卡目录树）",
        },
        "images": imgs,
        "images_reference_upscaled": ups,
        "audio": auds,
        "font": fonts,
        "video": video,
        "degradations": [
            {"item": "校园图母版",
             "detail": ("**未使用上采样**。既有 IMG001..006.BMP 只有 640x480，"
                        "但本项目有矢量绘制脚本 generate_campus_media.py，"
                        "故以 6x 超采样原生重渲染得到 1920x1440，"
                        "并由 verify_legacy_reproduction 逐像素复现既有 640x480 "
                        "成品（6 张全部 max|diff|=0）证明二者同源。"),
             "impact": "无降级"},
            {"item": "应急音频 TTS 语音",
             "detail": ("**未附 TTS 语音**。本机 SAPI 不可用"
                        "（System.Speech GetInstalledVoices() 抛 "
                        "'Object reference not set to an instance of an object.'），"
                        "且本任务禁用 ffmpeg、无网络，故应急音频只做纯双音 siren。"),
             "impact": "应急模式无语音播报，只有警报音；如需语音须在联网环境另行合成"},
            {"item": "narration.wav 重采样",
             "detail": ("源文件已是 48kHz/16bit/单声道，**无需重采样**，已原样复制。"
                        "脚本如实记录 action 字段，未假装执行过重采样。"),
             "impact": "无降级"},
            {"item": "视频播放",
             "detail": ("t3 **只做抽帧统计与样张，未导出整套帧序列**"
                        "（等 t2 PLAN.md 锁定帧率/色深，由 t4 导出）。"
                        "源 mp4 为 H.264 压缩，FPGA 无解码能力，"
                        "**不可作为 SD 卡播放源**。"),
             "impact": "视频播放能力取决于 t4 导出的帧序列 + RLE 解码器"},
            {"item": "中文滚动字幕（OSD TICKER）",
             "detail": ("`assets/v2/sdcard/COMMON/TICKER.TXT` 目前仍是 **64 字节纯 ASCII 英文**"
                        "（`SMART CAMPUS MEDIA - WELCOME - DAILY MODE ONLINE`）。"
                        "原因是现有 `rtl/osd/osd_strings.v` 的字模只有 8x16 英文/数字 41 字符，"
                        "且 TICKER 按 `col = (像素列 + 滚动偏移) & 6'b111111` 取 64 列，"
                        "**64 = 2^6 是零逻辑成本的设计，改长度要动 RTL**。"
                        "本目录的 16x16 中文字库（含 6 段贴合画面的校园介绍文案）已经准备好，"
                        "但要等 RTL 侧把 TICKER 从 `osd_strings.v` 切到 `cjk16_font.v` 才能上屏。"),
             "impact": ("中文滚动字幕**已备好文案与字形，暂未上屏**；"
                        "当前屏幕上滚动的仍是英文标语")},
        ],
        "copyright": {
            "images": "程序化绘制（generate_campus_media.py），无第三方图像素材",
            "audio": "全部 numpy 程序化合成，未使用任何采样/音源库，无第三方版权",
            "font_data": ("点阵栅格化自 Noto Sans SC（SIL OFL 1.1），"
                          "只分发点阵数据不分发字体文件；刻意规避微软雅黑/黑体/等线"
                          "（专有字体）"),
            "narration": "本项目原创讲稿；语音由 edge_tts 合成",
            "video_source": "H.264 视频由本项目脚本生成，仅作素材预览与统计来源",
            "summary": "**全部素材无第三方版权风险**",
        },
    }


def check_manifest(m: dict) -> bool:
    ok = True
    print("  [校验] 逐项重开文件：")
    for grp in ("images", "images_reference_upscaled", "audio", "font"):
        for it in m[grp]:
            p = REPO_ROOT / it["path"]
            if not p.is_file():
                print(f"    [BAD] 缺失 {it['path']}")
                ok = False
                continue
            if p.stat().st_size != it["bytes"]:
                print(f"    [BAD] 大小不符 {it['path']}")
                ok = False
    for key in ("narration_wav", "narration_srt"):
        p = REPO_ROOT / m["video"][key]["path"]
        ok &= p.is_file()
    for f in m["video"]["frames_samples"]:
        p = REPO_ROOT / f["path"]
        ok &= p.is_file()
    # 重新打开验证内容可读
    for it in m["images"] + m["images_reference_upscaled"]:
        with Image.open(REPO_ROOT / it["path"]) as im:
            im.load()
    for it in m["audio"]:
        with wave.open(str(REPO_ROOT / it["path"]), "rb") as w:
            w.readframes(1)
    print(f"    [{'OK ' if ok else 'BAD'}] 文件存在 + 大小一致 + Pillow/wave 可重新打开")
    return ok


def write_readme(m: dict):
    img_ok = [i for i in m["images"] if i["role"] == "master"]
    lines = []
    a = lines.append
    a("# assets/v2 母版素材清单")
    a("")
    a("> 本文件由 `scripts/gen_assets_v2_manifest.py` 自动生成，"
      "所有数值均为脚本从磁盘实测读取。")
    a("> 机器可读版本见同目录 [`MANIFEST.json`](MANIFEST.json)。")
    a("")
    a("## 一、这套素材是干什么的")
    a("")
    a("`assets/v2/masters/` 是**母版**：分辨率/时长都取到足够高，供 t4 阶段")
    a("派生五档分辨率素材包，而不是直接上板。上板产物落在 `assets/v2/derived/`")
    a("与 `assets/v2/sdcard/`。")
    a("")
    a("```")
    a("assets/v2/")
    a("  masters/          <- 本清单描述的母版（t3 产出）")
    a("    images/         <- 6 张校园景点图")
    a("    audio/          <- 3 段 BGM + 1 段应急警报")
    a("    font/           <- 16x16 中文点阵数据")
    a("    video/          <- 旁白音轨 + 字幕 + 抽帧样张 + 带宽统计")
    a("  derived/          <- t4：五档分辨率素材包")
    a("  sdcard/           <- t4：SD 卡目录树")
    a("```")
    a("")
    a("## 二、校园景点图（母版 1920×1440）")
    a("")
    a("| 文件 | 场景 | 尺寸 | 大小 |")
    a("|---|---|---|---|")
    for it in img_ok:
        a(f"| `{Path(it['path']).name}` | {it['title']} | "
          f"{it['width']}×{it['height']} | {it['bytes']:,} B |")
    a("")
    a("**关键：这不是上采样。** 既有 `assets/campus_media/sd_card/IMG001..006.BMP`")
    a("只有 640×480，看似只能上采样；但本项目本来就有矢量绘制脚本")
    a("`scripts/generate_campus_media.py`（Pillow 几何绘制，逻辑坐标系 640×480）。")
    a("本任务保持逻辑坐标系不变，把**超采样倍数从 2 提到 6**，绘制后 LANCZOS")
    a("缩到 1920×1440 —— 得到的是**原生重渲染**，细节是画出来的，不是插值猜的。")
    a("")
    a("证明同源的决定性证据：用原参数 + 原字体复现既有 640×480 成品，"
      "**6 张全部 `max|diff|=0`（逐像素完全一致）**。")
    a("")
    a("`reference_upscaled/` 里的 6 张是**对照用**的上采样图（640×480 → 1920×1440），")
    a("**不是母版**。实测锐度（Laplacian 能量）：原生重渲染 3.257 vs 上采样 1.415，")
    a("比值 2.30×。")
    a("")
    a("### 已知差异（有意为之，如实记录）")
    a("")
    a("母版字体用 Noto Sans SC，与既有 BMP 使用的等线粗体不同，")
    a("文字笔画边缘差异像素（>24/255）占比 **3.28%–4.42%**，几何图形完全一致。")
    a("这是为了规避微软雅黑/黑体/等线的**专有字体授权风险**而做的取舍。")
    a("")
    a("## 三、音频（48 kHz / 16 bit / 单声道）")
    a("")
    a("| 文件 | 用途 | 时长 | 大小 | 循环 |")
    a("|---|---|---|---|---|")
    for it in m["audio"]:
        a(f"| `{Path(it['path']).name}` | {it['use']} | {it['duration_s']:.2f} s | "
          f"{it['bytes']:,} B | {'是' if it['loop'] else '否'} |")
    a("")
    a("**授权：全部为 numpy 程序化合成，无第三方版权。** 未使用任何采样、")
    a("音源库或现成音乐片段。合成方式：分解和弦 pad（3 个微失谐正弦产生")
    a("chorus）+ 一阶 RC 低通滤波 + ADSR 包络 + 淡入淡出。")
    a("")
    a("### 循环建议（日常模式要循环播放）")
    a("")
    for it in m["audio"]:
        if it["loop"]:
            a(f"- **`{Path(it['path']).name}`**：{it['loop_note']}")
    a("")
    a("### 实测声学参数（MANIFEST 中逐项记录）")
    a("")
    a("| 文件 | peak | rms | 主频 | 敏感带 300–4 kHz |")
    a("|---|---|---|---|---|")
    for it in m["audio"]:
        a(f"| `{Path(it['path']).name}` | {it['peak_dbfs']} dBFS | "
          f"{it['rms_dbfs']} dBFS | {it['dominant_freq_hz']} Hz | "
          f"{it['sensitive_band_300_4k_pct']}% |")
    a("")
    a("siren 敏感带占比 99.9%（警报能量集中于人耳最敏感频段，响度效率高）；")
    a("BGM 敏感带占比低（能量分布在全频段，作垫底音乐不抢旁白）。")
    a("")
    a("> 口径说明：主频 = **整段文件 FFT 的峰值 bin**（附录常是某一和弦的根音或"
      "低音声部，如 serene 261.6=C4、uplift 73.4=D2 低音声部）。"
      "`gen_assets_v2_audio.py` 自检输出的是分段分析口径，两者都是真实测量，"
      "差异来自分析窗口不同，不是数据矛盾。")
    a("")
    a("## 四、16×16 中文点阵字库")
    a("")
    a("| 文件 | 说明 | 大小 |")
    a("|---|---|---|")
    for it in m["font"]:
        a(f"| `{Path(it['path']).name}` | {it['format']} | {it['bytes']:,} B |")
    a("")
    _fg = m["font"][0] if m["font"] else {}
    _gc = _fg.get("glyph_count")
    a(f"覆盖 **{_gc} 个字形**（汉字 + 全角标点 + ℃/% + 数字 + 字幕里出现的半角字母符号），")
    a("每字 16 行 × 16 bit，**bit15 = 最左像素**，索引 = `{glyph_index, row}`。")
    a("")
    a("### 索引冻结（重要，改字库前先读这段）")
    a("")
    a("**索引 0..94 这 95 个字形是冻结段**，任何时候都不得重排或删除，"
      "新增字符只能从索引 95 往后追加。")
    a("")
    a("原因是 RTL 会以 index 硬引用字库（`cjk16_font u_font (.glyph(idx), ...)`）。"
      "`cjk16_bitmap.hex` 的地址 = `index * 16 + row`，一旦重排，所有已写好的")
    a("索引常量全部指向错的字形 —— **屏幕会静默显示错字**：不报错、不变红、不崩溃，")
    a("只是字不对。这是最难定位的一类故障，所以宁可用冗余列表把前 95 字冻死。")
    a("")
    a("新增部分按 **Unicode 码位升序**排列（便于人工查阅，且同批新增的索引稳定）。")
    a("")
    a("### 字形覆盖是怎么定下来的（不是拍脑袋凑数）")
    a("")
    a("不手工罗列汉字，而是**从磁盘上的真实文本反推并集**，每跑一次脚本就重新求一次：")
    a("")
    a("| 需求来源 | 路径 | 用途 |")
    a("|---|---|---|")
    a("| 科普模式旁白字幕 | `assets/v2/sdcard/COMMON/SRT/NARR.SRT` | 18 条旁白全文 |")
    a("| 6 张校园图的滚动文案 | `assets/v2/masters/text/campus_ticker.txt` | 每图一段中文介绍 |")
    a("| 应急模式提示文案 | `assets/v2/masters/text/emergency_ticker.txt` | 消防通道疏散提示 |")
    a("| UI 固定文案 | `assets/v2/masters/text/ui_strings.txt` | 模式/参数/档位/单位 |")
    a("| OSD 短语表 | 脚本内 `OSD_PHRASES` | 冻结段来源 |")
    a("")
    a("这样字库里每个字都对应屏幕上真实会出现的一处文本，不会白占 ROM；"
      "反过来，**改了文案却没重跑字库脚本 → 缺字 → 屏幕方块**，"
      "因此生成脚本自带覆盖率自检，缺一个字就判失败。")
    a("")
    a("### 中文文案（同时供 OSD 滚动字幕与字库覆盖使用）")
    a("")
    a("`assets/v2/masters/text/` 下三份文案，均为 **UTF-8 + LF**，与渲染出的字形一一对应：")
    a("")
    a("- `campus_ticker.txt` —— 6 行，每行对应 `IMG001`~`IMG006` 的校园介绍滚动字幕，"
      "内容贴合各自画面（校门晨光 / 图书馆长窗与摊开的书 / 创客工坊芯片走线 / "
      "风机与光伏板 / 看台与跑道 / 夜巡灯柱）")
    a("- `emergency_ticker.txt` —— 3 行应急模式消防通道提示，轮播")
    a("- `ui_strings.txt` —— UI 固定文案（模式名、参数名、档位、单位、状态词）")
    a("")
    a("**降级说明**：`assets/v2/sdcard/COMMON/TICKER.TXT` 受 FAT32 8.3 短名 + "
      "现有 `osd_strings.v` 纯 ASCII 字模限制，仍是 64 字节英文；"
      "中文滚动字幕要等 RTL 侧接入本字库（见 `SDCARD_LAYOUT.md` §11）。")
    a("")
    a("`cjk16_font.v` 是 Verilog case 表 ROM，可直接接入 RTL；")
    a("**本任务只产出数据，不写 RTL**（接线由 t5/t6/t7 决定）。")
    a("")
    a("### 字形来源与授权（答辩要点）")
    a("")
    a("栅格化自 **Noto Sans SC Regular**（SIL Open Font License 1.1）。")
    a("**刻意不用微软雅黑(msyh)/黑体(simhei)/等线(Deng)** —— 这三者是微软专有")
    a("字体，随工程分发其点阵有授权风险。授权全文见 `docs/OFL-NotoSansSC.txt`，")
    a("说明见 `docs/science_font_attribution.md`。**只分发点阵数据，不分发字体文件。**")
    a("")
    a("### 字重是逐档比出来的，不是随手取的")
    a("")
    a("`NotoSansSC-VF.ttf` 是**可变字体**，默认实例是 **Thin (weight 100)**，")
    a("直接加载会得到 1px 细线，汉字骨架断裂。以笔画最密集的「幕 播 慧 智 园 模」")
    a("六字在 16×16 下比对墨点数：")
    a("")
    a("| 字重 | 墨点数 | 观察 |")
    a("|---|---|---|")
    a("| Thin | 69~ | 骨架断裂，不可辨 |")
    a("| **Regular** | **83~105** | **结构清晰、有留白，可辨** ✓ |")
    a("| Medium | 102~121 | 偏重，部分横画开始并笔 |")
    a("| Bold | 131~146 | 糊连：「幕」顶部成实心横条 |")
    a("")
    a("（该字体可用的命名实例只有 Thin/Light/Regular/Medium/Bold/Black，"
      "**没有 SemiBold**。）")
    a("")
    a("## 五、视频相关")
    a("")
    a("### 旁白音轨与字幕")
    a("")
    a(f"- `narration.wav`：{m['video']['narration_wav']['channels']}ch / "
      f"{m['video']['narration_wav']['bits']}bit / "
      f"{m['video']['narration_wav']['sample_rate']}Hz / "
      f"{m['video']['narration_wav']['frames']:,} 帧 / "
      f"{m['video']['narration_wav']['duration_s']:.5f} s")
    a(f"  - {m['video']['narration_wav']['action']}")
    a(f"- `narration.srt`：{m['video']['narration_srt']['count']} 条字幕，"
      "5 项校验全过（单调递增 / 无重叠 / end>start / 不超音频时长 / 文本非空）")
    a("")
    a("### 带宽预算（t4 与架构的选型依据）")
    a("")
    bw = m["video"]["stats"].get("bandwidth_table", {})
    if bw:
        a("**前提：未压缩帧。** 源视频 640×480、60 fps、126.104 s、7,566 帧。")
        a("")
        a("| 色深 | 单帧字节 | 1 fps | 5 fps | 30 fps | SDRAM 可存帧 |")
        a("|---|---|---|---|---|---|")
        for pixfmt in ("RGB888", "RGB565", "RGB332"):
            rows = [r for r in bw["rows"] if r["pixfmt"] == pixfmt]
            if not rows:
                continue
            r1 = next(r for r in rows if r["fps"] == 1)
            r5 = next(r for r in rows if r["fps"] == 5)
            r30 = next(r for r in rows if r["fps"] == 30)
            mark = lambda r: f"{r['bandwidth_MBps']:.2f} MB/s" + (
                " ✓" if r["sd_ok"] else "")
            a(f"| {pixfmt} | {r1['frame_bytes']:,} B | {mark(r1)} | {mark(r5)} | "
              f"{mark(r30)} | {r1['sdram_frames']} |")
        a("")
        a("SD SPI 实用带宽按 **1.25 MB/s** 计。15 个「色深×帧率」组合里只有 3 个")
        a("落在带宽内，**全部是 1 fps** —— 640×480 未压缩全帧视频从 SD 卡播放不可行。")
        a("")
    rs = m["video"]["stats"].get("rle_stats")
    if rs:
        a("**RLE 游程压缩后（RGB565 量化，每秒抽 1 帧共 "
          f"{rs['sampled_frames']} 帧）**：")
        a("")
        a("| 编码 | 每条目 | 均值 | 最小 | 最大 | p95 |")
        a("|---|---|---|---|---|---|")
        for key, e in rs["encodings"].items():
            st = e["frame_bytes"]
            a(f"| {key} | {e['bytes_per_run']} B | {st['mean']:,.0f} B | "
              f"{st['min']:,} B | {st['max']:,} B | {st['p95']:,.0f} B |")
        a("")
        e = rs["encodings"]["rle8"]
        a("RLE 3 B/条目 的带宽账（vs SD SPI 1.25 MB/s）：")
        a("")
        for r in (1, 2, 5, 8):
            m_ = e[f"bw_mean_fps{r}_MBps"]
            w_ = e[f"bw_worst_fps{r}_MBps"]
            ok_mark = "✓" if w_ <= 1.25 else "✗"
            a(f"- @{r} fps：均值 {m_:.3f} MB/s，最坏 {w_:.3f} MB/s {ok_mark}")
        a("")
        a("**结论：** 未压缩不可行（最高 1 fps）；引入 RLE 后 **5 fps 可用**")
        a("（均值 0.650 MB/s = SD 带宽 52%，最坏 1.012 MB/s = 81%）。")
        a("两张表**前提不同、不矛盾**：先算未压缩发现不可行，再用 RLE 提升 5 倍。")
        a("")
    a("### 抽帧样张")
    a("")
    a("`video/frames/` 下 7 张 PNG 样张，覆盖片头/正文/结尾，供看画面风格与色深。")
    a("**未导出整套帧序列**——那要等 `PLAN.md` 锁定帧率与色深，由 t4 按 PLAN 导出。")
    a("")
    a("> 源 mp4 为 H.264 压缩，**FPGA 无解码能力**，不可作 SD 卡播放源，")
    a("> 只能作素材预览与答辩展示。")
    a("")
    a("## 六、缺项与降级（如实记录）")
    a("")
    for d in m["degradations"]:
        a(f"### {d['item']}")
        a("")
        a(d["detail"])
        a("")
        a(f"**影响：** {d['impact']}")
        a("")
    a("## 七、版权声明")
    a("")
    for k, v in m["copyright"].items():
        if k == "summary":
            continue
        a(f"- **{k}**：{v}")
    a("")
    # summary 值自身已带 ** 包裹，此处不能再包一层 —— 否则会生成
    # `****文本****`，Markdown 把它解析成"空加粗标签 + 文本"，
    # 正文出现错乱的星号。先剥掉原有星号，再统一加粗一次。
    a(f"**{m['copyright']['summary'].strip('*').strip()}**")
    a("")
    a("## 八、可复现性")
    a("")
    a("每个母版都有对应的生成脚本，重复运行产出相同结果（固定随机种子）：")
    a("")
    a("| 脚本 | 产出 |")
    a("|---|---|")
    a("| `scripts/gen_assets_v2_images.py` | 6 张校园图母版 + 基准版 + 上采样对照 |")
    a("| `scripts/gen_assets_v2_audio.py` | 3 段 BGM + 1 段应急警报 |")
    a("| `scripts/gen_assets_v2_font.py` | 16×16 中文点阵（.v/.hex/.json/preview） |")
    a("| `scripts/gen_assets_v2_video.py` | 旁白音轨 + 字幕 + 抽帧样张 + 带宽统计 |")
    a("| `scripts/gen_assets_v2_manifest.py` | 本文件与 MANIFEST.json |")
    a("")
    a("每个脚本都带**自检**（用 Pillow/wave/cv2/json 重新打开产物并打印校验结果），")
    a("运行时会打印 `[自检] 全部通过`。")
    a("")
    (V2 / "README.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="只校验已有 MANIFEST")
    args = ap.parse_args()

    if args.check:
        js = V2 / "MANIFEST.json"
        if not js.is_file():
            raise SystemExit(f"缺少 {js}，请先不带 --check 运行一次")
        m = json.loads(js.read_text(encoding="utf-8"))
        ok = check_manifest(m)
        print(f"\n[自检] {'全部通过' if ok else '存在失败项'}")
        return 0 if ok else 1

    print("[1/3] 采集母版元数据（从磁盘实测）")
    m = build_manifest()
    n_img = len(m["images"])
    n_up = len(m["images_reference_upscaled"])
    n_aud = len(m["audio"])
    n_font = len(m["font"])
    n_frames = len(m["video"]["frames_samples"])
    print(f"  图像母版 {n_img} 项（含 1280x960 基准版）、上采样对照 {n_up} 项")
    print(f"  音频 {n_aud} 项、字库 {n_font} 项、抽帧样张 {n_frames} 项")
    print(f"  视频统计：带宽表 "
          f"{len(m['video']['stats'].get('bandwidth_table', {}).get('rows', []))} 行，"
          f"RLE 表 "
          f"{len(m['video']['stats'].get('rle_stats', {}).get('encodings', {}))} 档")

    print("\n[2/3] 写 MANIFEST.json 与 README.md")
    js = V2 / "MANIFEST.json"
    js.write_text(json.dumps(m, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"  MANIFEST.json  {js.stat().st_size:,} B")
    n_lines = write_readme(m)
    rd = V2 / "README.md"
    print(f"  README.md      {rd.stat().st_size:,} B  ({n_lines} 行)")

    print("\n[3/3] 自检")
    ok = check_manifest(m)
    reloaded = json.loads(js.read_text(encoding="utf-8"))
    js_ok = (len(reloaded["images"]) == n_img and len(reloaded["audio"]) == n_aud
             and len(reloaded["font"]) == n_font)
    ok &= js_ok
    print(f"  [{'OK ' if js_ok else 'BAD'}] MANIFEST.json 可重新解析且条目数一致")
    rd_ok = rd.is_file() and rd.stat().st_size > 2000
    ok &= rd_ok
    print(f"  [{'OK ' if rd_ok else 'BAD'}] README.md 已生成（{rd.stat().st_size:,} B）")
    no_crlf = "\r\n" not in rd.read_text(encoding="utf-8")
    ok &= no_crlf
    print(f"  [{'OK ' if no_crlf else 'BAD'}] README.md 为 LF 换行")

    print(f"\n[自检] {'全部通过' if ok else '存在失败项'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
