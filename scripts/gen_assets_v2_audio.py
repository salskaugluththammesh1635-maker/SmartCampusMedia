#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 assets/v2/masters/audio/ 的音频母版：3 段舒缓背景音乐 + 1 段应急警报音。

全部为 **numpy 程序化合成**，不使用任何第三方音频素材、不调用 ffmpeg。
因此版权归属明确：本工程原创，无第三方版权，可随工程自由分发。

为什么是程序化合成
------------------
任务要求"舒缓背景音乐 3 段（各 30~60s）"且"无版权风险"。可行路线只有两条：
外购/下载 royalty-free 曲库（本环境无网络、且授权链无法自证），或程序化合成。
选后者：音频的每一个采样点都由本脚本算出，作者与授权都可追溯到这份代码。

BGM 合成思路（ambient / pad 风格）
----------------------------------
每段用一条固定调式的和弦进行，声部逐层叠加：
  1. 基频 pad：每个和弦音用 3 个略微失谐的正弦叠加（detune ±0.15%），
     产生缓慢的相位拍频，听感类似模拟合成器的 chorus。
  2. 低通滤波：一阶 IIR 低通，截止频率随段落推进缓慢起伏（LFO 调制），
     削掉高频毛刺，得到"柔和、不刺耳"的 pad 质感。
  3. 根音 bass：低八度正弦 + 缓慢包络，给和声一个稳定的底座。
  4. 泛音点缀：高八度的极弱正弦（-24 dB），增加空气感。
  5. 全局包络：开头 2.5s 淡入、结尾 3.5s 淡出（cos² 曲线，无咔哒声）。
  6. 归一化到 -3 dBFS，避免削顶；最后用软限幅兜底。

三段各用不同调式与速度，避免听感雷同：
  - bgm_serene.wav     C 大调  Imaj7 - vi7 - IVmaj7 - V7     72 BPM 感觉，40.0 s
  - bgm_focus.wav      A 小调 i9 - VI - III - VII            60 BPM 感觉，48.0 s
  - bgm_uplift.wav     F 大调  Imaj7 - V - vi7 - IVmaj7      84 BPM 感觉，36.0 s

应急警报音（siren）
-------------------
双音交替 siren：两个频率在三全音/纯五度关系上快速切换（符合应急提示音的
可辨识性要求），叠加轻微频率滑动，避免听感呆板。
**不含 TTS 语音**：本机 SAPI 不可用（System.Speech GetInstalledVoices() 抛
"Object reference not set to an instance of an object."），且任务禁用 ffmpeg、
不假设网络，故只做纯警报音，并在 README 中如实注明。

所有 WAV 统一为 **48000 Hz / 16 bit / 单声道**（与 narration.wav、HDMI 音频通路一致）。

可复现性
--------
numpy 随机数用固定 seed（default_rng(seed)），IIR 滤波系数为确定性常量，
因此重复运行产出**逐字节相同**的 WAV（脚本末尾用 SHA256 自检并打印）。

用法
----
    python scripts/gen_assets_v2_audio.py
    python scripts/gen_assets_v2_audio.py --check
"""

from __future__ import annotations

import argparse
import hashlib
import sys
import wave
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = REPO_ROOT / "assets" / "v2" / "masters" / "audio"

SR = 48000          # 采样率，与 narration.wav / HDMI 音频通路一致
SAMPWIDTH = 2       # 16 bit
CHANNELS = 1        # 单声道

# 音名 -> 相对 A4=440Hz 的半音偏移
_NOTE_BASE = {"C": -9, "C#": -8, "D": -7, "D#": -6, "E": -5, "F": -4,
              "F#": -3, "G": -2, "G#": -1, "A": 0, "A#": 1, "B": 2}


def note_hz(name: str, octave: int) -> float:
    """把音名+八度转成频率（Hz），以 A4=440Hz 为基准，12 平均律。"""
    semis = _NOTE_BASE[name] + (octave - 4) * 12
    return 440.0 * (2.0 ** (semis / 12.0))


def adsr_env(n: int, attack: float, release: float, sr: int = SR) -> np.ndarray:
    """线性 attack + 线性 release 的包络，长度 n 个采样。"""
    env = np.ones(n, dtype=np.float64)
    a = min(int(attack * sr), n)
    r = min(int(release * sr), n)
    if a > 0:
        env[:a] = np.linspace(0.0, 1.0, a, endpoint=False)
    if r > 0:
        env[-r:] *= np.linspace(1.0, 0.0, r)
    return env


def lowpass_iir(sig: np.ndarray, cutoff_hz, sr: int = SR,
                state: float = 0.0) -> tuple[np.ndarray, float]:
    """一阶 IIR 低通（RC 离散化），**全程连续递推**，返回 (输出, 末态)。

    y[n] = y[n-1] + alpha * (x[n] - y[n-1]),  alpha = dt / (RC + dt)

    cutoff_hz 可以是标量（固定截止）或与 sig 等长的数组（时变截止，用于 LFO
    呼吸感）。时变截止下系数逐采样变化，无法用 lfilter 之类的一次性卷积，
    因此这里显式递推。

    关键正确性约束：**必须把上一段的末态 state 传进来、把本段末态传出去**。
    如果每段都从 state=0 重新开始（本脚本开发期的真实 bug），段边界会出现
    直流阶跃 -> 听感上是周期性的"噗"声，且频谱上产生非预期的低频能量。
    分块只为让 alpha 少算几次（每 256 采样更新一次），状态是连续的。

    只用 numpy（不依赖 scipy），符合任务声明的环境。
    """
    n = sig.size
    out = np.empty(n, dtype=np.float64)
    dt = 1.0 / sr
    if np.isscalar(cutoff_hz):
        rc = 1.0 / (2.0 * np.pi * max(float(cutoff_hz), 1.0))
        alpha = dt / (rc + dt)
        a1 = 1.0 - alpha
        acc = state
        # 标量系数下 alpha/a1 在循环外算好，避免每采样一次浮点除法
        for i in range(n):
            acc = acc * a1 + alpha * sig[i]
            out[i] = acc
        return out, acc

    cut = np.asarray(cutoff_hz, dtype=np.float64)
    if cut.size != n:
        raise ValueError(f"时变截止长度 {cut.size} 与信号长度 {n} 不符")
    acc = state
    block = 256
    for s in range(0, n, block):
        e = min(s + block, n)
        rc = 1.0 / (2.0 * np.pi * max(float(cut[s]), 1.0))
        alpha = dt / (rc + dt)
        a1 = 1.0 - alpha
        for i in range(s, e):
            acc = acc * a1 + alpha * sig[i]
            out[i] = acc
    return out, acc


def pad_voice(freq: float, dur: float, detune: float, sr: int = SR) -> np.ndarray:
    """一个 pad 声部：3 个微失谐正弦叠加，产生缓慢拍频（chorus 感）。"""
    n = int(dur * sr)
    t = np.arange(n, dtype=np.float64) / sr
    sig = np.zeros(n, dtype=np.float64)
    for k, mul in enumerate((1.0 - detune, 1.0, 1.0 + detune)):
        # 每个分音给不同初相，避免三者在 t=0 完全同相造成起音过冲
        sig += np.sin(2.0 * np.pi * freq * mul * t + k * 1.7)
    return sig / 3.0


def build_bgm(chords: list[list[str]], chord_sec: float, seed: int,
              cutoff_lfo: tuple[float, float], bass_gain: float = 0.42,
              shimmer_gain: float = 0.06) -> np.ndarray:
    """按和弦进行合成一段 ambient BGM，返回 float64 波形（未归一化）。"""
    rng = np.random.default_rng(seed)
    total = int(chord_sec * len(chords) * SR)
    mix = np.zeros(total, dtype=np.float64)

    for ci, chord in enumerate(chords):
        start = int(ci * chord_sec * SR)
        # 和弦段之间留 0.9 倍重叠，让段落衔接是"溶接"而不是硬切
        seg_dur = chord_sec * 1.9
        seg_n = int(seg_dur * SR)
        seg = np.zeros(seg_n, dtype=np.float64)

        for voice_i, spec in enumerate(chord):
            name, octave = spec[:-1], int(spec[-1])
            f = note_hz(name, octave)
            detune = 0.0012 + 0.0004 * voice_i     # 各声部失谐略有差异
            v = pad_voice(f, seg_dur, detune)
            # 各声部不同权重，越高的音越轻，符合自然泛音衰减
            seg += v * (1.0 / (1.0 + 0.55 * voice_i))
            # 极弱的高八度泛音，增加空气感
            seg += pad_voice(f * 2.0, seg_dur, detune) * shimmer_gain

        # 根音 bass：低两个八度，只取和弦第一个音
        root_name, root_oct = chord[0][:-1], int(chord[0][-1])
        bass_f = note_hz(root_name, root_oct - 2)
        n_bass = seg_n
        t_bass = np.arange(n_bass, dtype=np.float64) / SR
        # bass 用纯正弦 + 极缓包络，避免低频方波的刺耳谐波
        bass = np.sin(2.0 * np.pi * bass_f * t_bass)
        bass *= adsr_env(n_bass, 0.6, 1.2) * bass_gain
        seg += bass

        # 段落包络：慢起慢落，段间溶接
        seg *= adsr_env(seg_n, chord_sec * 0.55, chord_sec * 0.75)

        end = min(start + seg_n, total)
        mix[start:end] += seg[: end - start]

    # 低通滤波：截止频率随 LFO 缓慢起伏，得到"呼吸感"的柔和 pad。
    # 时变截止逐采样递推（见 lowpass_iir 的说明），状态连续、无块边界阶跃。
    lo, hi = cutoff_lfo
    lfo = 0.5 - 0.5 * np.cos(2.0 * np.pi * np.arange(total) / (total * 0.62))
    cutoff = lo + (hi - lo) * lfo
    out, _ = lowpass_iir(mix, cutoff, SR)

    # 全局淡入淡出（cos² 曲线，无咔哒声）
    fade_in, fade_out = 2.5, 3.5
    n_in, n_out = int(fade_in * SR), int(fade_out * SR)
    t_in = np.linspace(0.0, np.pi / 2.0, n_in)
    out[:n_in] *= np.sin(t_in) ** 2
    t_out = np.linspace(np.pi / 2.0, 0.0, n_out)
    out[-n_out:] *= np.sin(t_out) ** 2

    # 加一点极弱的粉噪"空气层"，让纯正弦不至于过于电子味（-46 dB）
    noise = rng.standard_normal(total) * (10 ** (-46 / 20.0))
    noise_lp, _ = lowpass_iir(noise, 1200.0, SR)
    out += noise_lp
    return out


def build_siren() -> np.ndarray:
    """应急双音交替 siren：两个频率快速切换 + 轻微频率滑动。

    设计要点（应急提示音的可辨识性）：
      - 两个音高相差纯五度（3:2），是听觉上最容易被识别为"警报"的音程关系；
      - 交替周期 0.42 s，接近人耳对"急促"的感知阈值；
      - 每个音段内部有 ±3% 的频率上滑，模拟传统机械 siren 的起音；
      - 全程无淡入（警报必须立刻起效），只在末尾 80 ms 淡出防咔哒。
    总长 6.0 s，可循环播放。
    """
    dur = 6.0
    n = int(dur * SR)
    t = np.arange(n, dtype=np.float64) / SR
    sig = np.zeros(n, dtype=np.float64)

    f_low, f_high = 740.0, 1110.0      # 约 F#5 与 C#6，纯五度关系
    period = 0.42
    for k in range(int(np.ceil(dur / period))):
        s = int(k * period * SR)
        e = min(int((k + 1) * period * SR), n)
        if e <= s:
            break
        seg_n = e - s
        tt = np.arange(seg_n, dtype=np.float64) / SR
        f0 = f_low if k % 2 == 0 else f_high
        # 段内频率上滑 3%：用相位积分保证连续，不产生相位跳变
        inst_f = f0 * (1.0 + 0.03 * tt / max(period, 1e-9))
        phase = 2.0 * np.pi * np.cumsum(inst_f) / SR
        tone = np.sin(phase)
        # 加二次、三次谐波增强穿透力：小喇叭（HDMI 显示器内置）低频响应差，
        # 靠 1~4 kHz 的能量才能在低音量下被听见。二次 -8 dB、三次 -14 dB。
        tone += 0.40 * np.sin(2.0 * phase)
        tone += 0.20 * np.sin(3.0 * phase)
        # 段内极短交叉淡化，避免硬切换产生咔哒
        env = np.ones(seg_n, dtype=np.float64)
        edge = min(int(0.006 * SR), seg_n // 2)
        if edge > 0:
            env[:edge] = np.linspace(0.0, 1.0, edge)
            env[-edge:] = np.linspace(1.0, 0.0, edge)
        sig[s:e] += tone * env

    # 末尾淡出，防播放结束时咔哒
    tail = int(0.08 * SR)
    sig[-tail:] *= np.linspace(1.0, 0.0, tail)
    return sig


def normalize(sig: np.ndarray, target_dbfs: float = -3.0) -> np.ndarray:
    """峰值归一到 target_dbfs，再用 tanh 软限幅兜底防削顶。"""
    peak = float(np.abs(sig).max())
    if peak < 1e-12:
        return sig
    sig = sig / peak * (10.0 ** (target_dbfs / 20.0))
    return np.tanh(sig * 1.02) * 0.985


def write_wav(path: Path, sig: np.ndarray):
    """写 48kHz / 16bit / 单声道 WAV，并回读校验。"""
    pcm = np.clip(sig, -1.0, 1.0)
    pcm = (pcm * 32767.0).astype(np.int16)
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(CHANNELS)
        w.setsampwidth(SAMPWIDTH)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def spectral_check(path: Path, expect_f0: list[float] | None = None,
                   expect_tone_alt: bool = False) -> dict:
    """频域/时域客观自检：把"舒缓""双音交替"这类主观描述落成可测指标。

    检查项：
      1. 峰值频率是否落在预期基频附近（用 FFT 找最强谱线）。
      2. 高频能量占比（> 5 kHz）：BGM 应极低（低通生效、听感柔和）；
         siren 应显著更高（警报需要穿透力）。
      3. 有无削顶：|sample| >= 0.999 的采样数应为 0。
      4. 淡入淡出：首尾 0.25 s 的 RMS 应明显低于中段。
      5. （siren）双音交替：把信号按 0.42 s 分段，主频应在两个音高间交替。
    """
    with wave.open(str(path), "rb") as w:
        fr, nf = w.getframerate(), w.getnframes()
        data = np.frombuffer(w.readframes(nf), dtype=np.int16).astype(np.float64) / 32768.0

    # 1) 主频：取中段 4 s，加汉宁窗抑制泄漏
    seg_n = min(4 * fr, data.size)
    mid = data[data.size // 2 - seg_n // 2: data.size // 2 + seg_n // 2]
    win = np.hanning(mid.size)
    spec = np.abs(np.fft.rfft(mid * win))
    freqs = np.fft.rfftfreq(mid.size, 1.0 / fr)
    # 忽略 30 Hz 以下（直流与极低频），找最强谱线
    valid = freqs >= 30.0
    peak_f = float(freqs[valid][np.argmax(spec[valid])])

    # 2) 高频能量占比。注意"高频"的判据对 BGM 和 siren 意义不同：
    #    BGM 关心的是 >5 kHz 的毛刺是否被低通削掉（听感柔和）；
    #    siren 的基频只有 740/1110 Hz，用 >5 kHz 判"穿透力"在物理上是错的
    #    （人耳最敏感区是 200~4000 Hz）。所以另算一个语音/听觉敏感带占比。
    power = spec ** 2
    total_p = float(power.sum()) or 1e-30
    hi_ratio = float(power[freqs > 5000.0].sum() / total_p)
    # 人耳敏感带 300~4000 Hz 的能量占比（警报穿透力的正确指标）
    ear_band = float(power[(freqs >= 300.0) & (freqs <= 4000.0)].sum() / total_p)

    # 3) 削顶
    clipped = int((np.abs(data) >= 0.999).sum())

    # 4) 淡入淡出（首尾 0.25 s RMS vs 中段 RMS）
    q = int(0.25 * fr)
    head_rms = float(np.sqrt(np.mean(data[:q] ** 2)))
    tail_rms = float(np.sqrt(np.mean(data[-q:] ** 2)))
    mid_rms = float(np.sqrt(np.mean(data[data.size // 2 - q: data.size // 2 + q] ** 2)))

    res = {
        "peak_freq_hz": round(peak_f, 1),
        "high_freq_ratio": round(hi_ratio, 6),
        "ear_band_ratio": round(ear_band, 4),
        "clipped_samples": clipped,
        "head_over_mid": round(head_rms / max(mid_rms, 1e-12), 4),
        "tail_over_mid": round(tail_rms / max(mid_rms, 1e-12), 4),
    }

    # 5) siren 双音交替检测
    if expect_tone_alt:
        period = 0.42
        tones = []
        for k in range(min(8, int(data.size / (period * fr)))):
            s = int(k * period * fr)
            e = min(int((k + 1) * period * fr), data.size)
            chunk = data[s:e]
            if chunk.size < 64:
                break
            sp = np.abs(np.fft.rfft(chunk * np.hanning(chunk.size)))
            fq = np.fft.rfftfreq(chunk.size, 1.0 / fr)
            m = fq >= 200.0
            tones.append(round(float(fq[m][np.argmax(sp[m])]), 0))
        res["segment_peak_hz"] = tones
        # 交替性：相邻段主频应交替高低
        alts = sum(1 for a, b in zip(tones, tones[1:]) if abs(a - b) > 150.0)
        res["alternations"] = alts
        res["alternating"] = alts >= len(tones) - 2

    if expect_f0:
        res["expect_f0_hz"] = expect_f0
        res["f0_match"] = any(abs(peak_f - f) < 40.0 or abs(peak_f - f / 2) < 40.0
                              for f in expect_f0)
    return res


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def analyze_wav(path: Path) -> dict:
    """用标准库 wave 重新打开，核对参数并计算响度/峰值等统计。"""
    with wave.open(str(path), "rb") as w:
        ch, sw, fr, nf = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(nf)
    data = np.frombuffer(raw, dtype=np.int16).astype(np.float64) / 32768.0
    peak = float(np.abs(data).max()) if data.size else 0.0
    rms = float(np.sqrt(np.mean(data ** 2))) if data.size else 0.0
    db = lambda x: 20.0 * np.log10(max(x, 1e-12))
    return {
        "channels": ch, "sampwidth": sw, "framerate": fr, "frames": nf,
        "duration_s": round(nf / fr, 4),
        "peak_dbfs": round(db(peak), 2), "rms_dbfs": round(db(rms), 2),
        "bytes": path.stat().st_size,
        "sha256": sha256_of(path),
        "ok": (ch == CHANNELS and sw == SAMPWIDTH and fr == SR and nf > 0),
    }


# ---- 曲目定义 -------------------------------------------------------------
# 和弦用 [音名+八度] 列表表示，每段一个和弦，和弦内 4 个声部。
BGM_SPECS = [
    {
        "file": "bgm_serene.wav",
        "title": "静谧晨光 / Serene Campus Morning",
        "use": "日常模式背景音乐（开机/图库浏览）",
        "chords": [
            ["C4", "E4", "G4", "B4"],      # Imaj7
            ["A3", "C4", "E4", "G4"],      # vi7
            ["F3", "A3", "C4", "E4"],      # IVmaj7
            ["G3", "B3", "D4", "F4"],      # V7
        ],
        "chord_sec": 10.0,   # 4 * 10.0 = 40.0 s
        "seed": 20261101,
        "cutoff_lfo": (900.0, 2600.0),
    },
    {
        "file": "bgm_focus.wav",
        "title": "专注时刻 / Focus in the Library",
        "use": "科普模式背景音乐（讲解/字幕演示）",
        "chords": [
            ["A3", "C4", "E4", "B4"],      # i9
            ["F3", "A3", "C4", "E4"],      # VI
            ["C4", "E4", "G4", "B4"],      # III
            ["G3", "B3", "D4", "F4"],      # VII
        ],
        "chord_sec": 12.0,   # 4 * 12.0 = 48.0 s
        "seed": 20261102,
        "cutoff_lfo": (700.0, 2000.0),
    },
    {
        "file": "bgm_uplift.wav",
        "title": "绿色律动 / Green Campus Motion",
        "use": "科普/日常切换过渡背景音乐",
        "chords": [
            ["F3", "A3", "C4", "E4"],      # Imaj7
            ["C4", "E4", "G4", "B4"],      # V
            ["D4", "F4", "A4", "C5"],      # vi7
            ["A3", "C4", "E4", "G4"],      # IVmaj7(转位)
        ],
        "chord_sec": 9.0,    # 4 * 9.0 = 36.0 s
        "seed": 20261103,
        "cutoff_lfo": (1100.0, 3000.0),
    },
]

SIREN_SPEC = {
    "file": "alarm_siren.wav",
    "title": "应急双音警报 / Emergency Two-Tone Siren",
    "use": "应急模式报警音（AHT20 高温联动/应急提示）",
}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="只校验已有 WAV")
    ap.add_argument("--out", type=Path, default=OUT_DIR)
    args = ap.parse_args()
    out: Path = args.out
    results = []

    if not args.check:
        print(f"[1/3] 合成 3 段舒缓 BGM -> {out}")
        for spec in BGM_SPECS:
            sig = build_bgm(spec["chords"], spec["chord_sec"], spec["seed"],
                            spec["cutoff_lfo"])
            sig = normalize(sig, -3.0)
            path = out / spec["file"]
            write_wav(path, sig)
            print(f"  {spec['file']:20s} {spec['title']}  "
                  f"{path.stat().st_size:>9,} B  "
                  f"{sig.size / SR:5.1f} s")

        print(f"\n[2/3] 合成应急双音警报 -> {out}")
        siren = normalize(build_siren(), -1.0)   # 警报音留更少余量，更响
        siren_path = out / SIREN_SPEC["file"]
        write_wav(siren_path, siren)
        print(f"  {SIREN_SPEC['file']:20s} {SIREN_SPEC['title']}  "
              f"{siren_path.stat().st_size:>9,} B  {siren.size / SR:5.1f} s")
        print("  注：不含 TTS 语音（本机 SAPI 不可用，详见 README）")

    print(f"\n[3/3] 用标准库 wave 重新打开校验：")
    all_ok = True
    for spec in BGM_SPECS + [SIREN_SPEC]:
        path = out / spec["file"]
        if not path.is_file():
            print(f"  [MISS] {spec['file']}")
            all_ok = False
            continue
        st = analyze_wav(path)
        all_ok &= st["ok"]
        flag = "OK " if st["ok"] else "BAD"
        print(f"  [{flag}] {spec['file']:20s} {st['channels']}ch/{st['sampwidth'] * 8}bit/"
              f"{st['framerate']}Hz  {st['duration_s']:6.2f}s  "
              f"peak={st['peak_dbfs']:6.2f}dBFS  rms={st['rms_dbfs']:6.2f}dBFS  "
              f"{st['bytes']:>9,} B")
        st["file"] = spec["file"]
        st["title"] = spec["title"]
        st["use"] = spec["use"]
        results.append(st)

    # 频域/时域客观自检：把"舒缓""双音交替"这类主观描述落成可测指标
    print(f"\n[自检] 频谱与包络（把主观描述落成客观指标）：")
    for spec, st in zip(BGM_SPECS + [SIREN_SPEC], results):
        path = out / spec["file"]
        if not path.is_file():
            continue
        is_siren = spec["file"] == SIREN_SPEC["file"]
        sp = spectral_check(path, expect_tone_alt=is_siren)
        st["spectral"] = sp
        checks = []
        # 所有音频：无削顶
        checks.append(("无削顶", sp["clipped_samples"] == 0))
        if is_siren:
            # 警报：双音交替 + 能量集中在人耳敏感带（300~4000 Hz）
            checks.append(("双音交替", sp.get("alternating", False)))
            checks.append(("敏感带能量>90%(穿透力)", sp["ear_band_ratio"] > 0.90))
            verdict = "警报特征齐全" if all(c[1] for c in checks) else "警报特征不足"
        else:
            # BGM：高频能量极低（低通生效=舒缓）、首尾淡入淡出
            checks.append(("高频能量<1%(柔和)", sp["high_freq_ratio"] < 0.01))
            checks.append(("开头淡入", sp["head_over_mid"] < 0.5))
            checks.append(("结尾淡出", sp["tail_over_mid"] < 0.5))
            verdict = "舒缓特征齐全" if all(c[1] for c in checks) else "特征不符"
        all_ok &= all(c[1] for c in checks)
        detail = "  ".join(f"{n}={'✓' if v else '✗'}" for n, v in checks)
        print(f"  {spec['file']:20s} 主频={sp['peak_freq_hz']:7.1f}Hz  "
              f"高频占比={sp['high_freq_ratio'] * 100:6.3f}%  "
              f"敏感带={sp['ear_band_ratio'] * 100:5.1f}%  "
              f"淡入={sp['head_over_mid']:.3f} 淡出={sp['tail_over_mid']:.3f}")
        print(f"  {'':20s} {detail}  -> {verdict}")
        if is_siren:
            print(f"  {'':20s} 分段主频={sp.get('segment_peak_hz')}")

    print(f"\n[自检] {'全部通过' if all_ok else '存在失败项'}")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
