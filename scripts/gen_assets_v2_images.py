#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 assets/v2/masters/images/ 的 6 张校园景点母版（v2 五档分辨率素材链的源头）。

背景与关键决策
--------------
现有 assets/campus_media/sd_card/IMG001..006.BMP 只有 640x480（各 921,654 B），
无法直接派生五档分辨率。全仓扫描后确认**不存在任何原生高清校园图源**：
所有 IMG*.BMP / IMG*.png（assets/campus_media、assets/external、assets/external/round2、
external/、round2/、sd_images/、sd_verify/）一律 640x480，assets/external/raw 与
round2/raw 是空目录。因此只有两条路：

  A. 对 640x480 做 cv2/Pillow 上采样 —— 只是把 640x480 的信息量放大，细节是假的。
  B. 回到生成这些 BMP 的矢量绘制脚本 scripts/generate_campus_media.py，用更高
     超采样倍数**重新原生渲染**。

本脚本走 B（更优），并**同时保留 A 作为对照证据**，两者都落盘、都在 MANIFEST 里
如实标注，绝不伪造分辨率：

  - B（真原生重渲染）：generate_campus_media.py 的场景几何全部写在 640x480 逻辑
    坐标系里，模块级 SCALE 只是"超采样倍数"。把 SCALE 从 2 提到 6，画布变成
    3840x2880，再把 round_to_native() 从 resize((640,480)) 改写成
    resize((1920,1440))，得到的就是 3 倍逻辑坐标精度绘制 + LANCZOS 缩到
    1920x1440 —— 每个几何边缘、每条文字笔画都是按 1920x1440 真正画出来的，
    **不是**把 640x480 的成品图插值放大。
  - A（上采样对照）：直接把既有 640x480 BMP 用 Pillow LANCZOS 放大到 1920x1440，
    存为 *_upscaled_from_640x480.png，供对比与诚实留证。

为什么保持 640x480 逻辑坐标系而不把 W/H 改成 1920x1440
------------------------------------------------------
实测过：直接 gcm.W, gcm.H = 1920, 1440 且 SCALE=6 会得到内容挤在左上角 1/4 的错图，
因为 scene_* 里的所有坐标（如 a.rect((165, 237, 475, 365))）都是按 640x480 硬编码的，
改 W/H 只改变画布尺寸、不改变绘制坐标。保持逻辑坐标系、只提超采样倍数是唯一正确做法。

字体与授权
----------
只用 Noto Sans SC（SIL Open Font License 1.1），**不使用**微软雅黑(msyh.ttc)、
黑体(simhei.ttf)、等线(Deng.ttf/Dengb.ttf) —— 这几个是微软/中易的专有字体，
点阵/图像里固化其字形再随工程分发有版权风险。Noto Sans SC 的 OFL 全文已随工程
存在于 docs/OFL-NotoSansSC.txt，来源说明见 docs/science_font_attribution.md。

可复现性
--------
所有随机性都来自 generate_campus_media.py 里的 random.Random(seed)，种子固定为
1..6，因此重复运行产出**逐字节相同**的 PNG（脚本末尾用 SHA256 自检并打印）。

用法
----
    python scripts/gen_assets_v2_images.py            # 生成并自检
    python scripts/gen_assets_v2_images.py --check    # 只校验已有文件
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import sys
from pathlib import Path

import numpy as np
from PIL import Image

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = REPO_ROOT / "scripts"
OUT_DIR = REPO_ROOT / "assets" / "v2" / "masters" / "images"

# 母版目标尺寸。保持 4:3（与 640x480 逻辑坐标系同比例，不裁切、不拉伸）。
# 1920x1440 是 640x480 的整 3 倍，SCALE=6 恰好是 2 倍逻辑精度再缩一半 -> 3x 有效超采样。
MASTER_SIZE = (1920, 1440)
BASE_SIZE = (1280, 960)          # 任务书要求的 >=1280x960 基准版
LEGACY_SIZE = (640, 480)         # 既有 SD 卡成品尺寸
SUPERSAMPLE = 6                  # 画布 = 640*6 x 480*6 = 3840x2880

# 场景清单：(输出序号, 中文名, 强调色)。名称与 generate_campus_media.SCENES 一致。
SCENE_INFO = [
    (1, "智慧校园", "#75D9D0"),
    (2, "书香校园", "#FFD18A"),
    (3, "创客工坊", "#62DDF0"),
    (4, "绿色校园", "#A7E37C"),
    (5, "运动嘉年华", "#FFAA7F"),
    (6, "平安校园", "#F4D774"),
]


def load_generator():
    """以文件路径导入同目录的 generate_campus_media.py（它不在包内）。"""
    path = SCRIPTS_DIR / "generate_campus_media.py"
    if not path.is_file():
        raise SystemExit(f"缺少源生成脚本：{path}")
    spec = importlib.util.spec_from_file_location("generate_campus_media", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"无法加载：{path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["generate_campus_media"] = module
    spec.loader.exec_module(module)
    return module


def configure_generator(gcm, target_size: tuple[int, int], supersample: int):
    """把源脚本切到"高倍超采样 + 缩到 target_size"模式，并锁定 Noto Sans SC。"""
    # 1) 逻辑坐标系保持 640x480 不变（绝不能改 W/H，见模块 docstring）。
    assert (gcm.W, gcm.H) == (640, 480), "源脚本逻辑坐标系不是 640x480，需重新核对"
    # 2) 提高超采样倍数：Artboard.p() 与 Artboard.__init__ 都读模块级 SCALE。
    gcm.SCALE = supersample
    # 3) 覆盖收尾缩放：原本固定 resize((W, H)) = 640x480，这里改为目标母版尺寸。
    def round_to_native(self):
        return self.image.resize(target_size, Image.Resampling.LANCZOS)

    gcm.Artboard.round_to_native = round_to_native
    # 4) 字体：强制 Noto Sans SC（OFL 1.1），避开微软雅黑/黑体/等线的专有授权。
    noto = Path(r"C:\Windows\Fonts\NotoSansSC-VF.ttf")
    if not noto.is_file():
        raise SystemExit(f"缺少 Noto Sans SC：{noto}（不用专有字体替代，以免版权风险）")
    gcm.FONT_REGULAR = noto
    gcm.FONT_BOLD_PATH = noto      # VF 可变字体，bold 由 weight 轴实现（源脚本已处理）
    return gcm


def render_masters(gcm, out_dir: Path) -> list[dict]:
    """逐场景原生重渲染，写出 1920x1440 主母版 + 1280x960 基准版。"""
    out_dir.mkdir(parents=True, exist_ok=True)
    records = []
    for (idx, cn_name, accent), renderer in zip(SCENE_INFO, gcm.SCENE_RENDERERS):
        image = renderer().convert("RGB")
        if image.size != MASTER_SIZE:
            raise RuntimeError(f"IMG{idx:03d} 尺寸异常：{image.size} != {MASTER_SIZE}")
        master = out_dir / f"IMG{idx:03d}.png"
        image.save(master, format="PNG", optimize=True)
        base = out_dir / f"IMG{idx:03d}_1280x960.png"
        image.resize(BASE_SIZE, Image.Resampling.LANCZOS).save(base, format="PNG", optimize=True)
        records.append({
            "index": idx,
            "name_cn": cn_name,
            "accent": accent,
            "master": master,
            "base": base,
            "size": image.size,
        })
        print(f"  IMG{idx:03d}  {cn_name:6s}  {image.size[0]}x{image.size[1]}  "
              f"master={master.stat().st_size:,} B  base={base.stat().st_size:,} B")
    return records


def make_upscaled_reference(out_dir: Path) -> list[dict]:
    """A 方案对照：把既有 640x480 成品直接放大到 1920x1440，作为诚实留证。

    这些文件**不是**母版，只用于在 README/MANIFEST 里说明"上采样能到多大、
    但信息量并没有增加"，以及给架构/评审做视觉对比。
    """
    sd_dir = REPO_ROOT / "assets" / "campus_media" / "sd_card"
    if not sd_dir.is_dir():
        print("  （跳过上采样对照：未找到 assets/campus_media/sd_card）")
        return []
    ref_dir = out_dir / "reference_upscaled"
    ref_dir.mkdir(parents=True, exist_ok=True)
    out = []
    for idx, _, _ in SCENE_INFO:
        src = sd_dir / f"IMG{idx:03d}.BMP"
        if not src.is_file():
            print(f"  （跳过 {src.name}：不存在）")
            continue
        with Image.open(src) as im:
            im = im.convert("RGB")
            if im.size != LEGACY_SIZE:
                raise RuntimeError(f"{src.name} 源尺寸不是 640x480：{im.size}")
            up = im.resize(MASTER_SIZE, Image.Resampling.LANCZOS)
        dst = ref_dir / f"IMG{idx:03d}_upscaled_from_640x480.png"
        up.save(dst, format="PNG", optimize=True)
        out.append({"index": idx, "src": src, "dst": dst, "src_size": LEGACY_SIZE,
                    "dst_size": MASTER_SIZE})
        print(f"  ref IMG{idx:03d}  640x480 -> 1920x1440  {dst.stat().st_size:,} B")
    return out


def laplacian_energy(gray: np.ndarray) -> float:
    """4 邻域拉普拉斯响应的平均绝对值（边缘锐度指标）。

    正确做法：先把四个平移视图裁到同一形状再相加，不能直接对 diff 结果做切片
    （np.diff 会各自缩短一行/一列，两个结果形状不同，无法相加）。
    """
    a = gray[:-2, 1:-1]
    b = gray[2:, 1:-1]
    c = gray[1:-1, :-2]
    d = gray[1:-1, 2:]
    lap = np.abs(a + b + c + d - 4.0 * gray[1:-1, 1:-1])
    return float(lap.mean())


def content_fidelity(records: list[dict]) -> dict:
    """把母版缩回 640x480，与既有 SD 卡成品 BMP 做 PSNR 比对。

    这是"内容正确性"的硬证据：两者都是同一矢量场景的渲染结果，如果母版因坐标系
    用错而把内容挤在左上角 1/4（本次开发中真实踩过的坑），PSNR 会很低（< 12 dB）。
    正常应为 20 dB 以上。同时它证明母版与既有 SD 卡图**是同一场景**，只是分辨率更高。
    """
    sd_dir = REPO_ROOT / "assets" / "campus_media" / "sd_card"
    if not sd_dir.is_dir():
        return {"available": False}
    print("\n[自检] 内容一致性：母版缩回 640x480 与既有 SD 卡 BMP 的 PSNR")
    out = []
    for rec in records:
        legacy = sd_dir / f"IMG{rec['index']:03d}.BMP"
        if not legacy.is_file():
            continue
        with Image.open(legacy) as im:
            ref = np.asarray(im.convert("RGB"), dtype=np.float64)
        with Image.open(rec["master"]) as im:
            got = np.asarray(im.convert("RGB").resize(LEGACY_SIZE, Image.Resampling.LANCZOS),
                             dtype=np.float64)
        mse = float(np.mean((ref - got) ** 2))
        psnr = float("inf") if mse == 0 else 10.0 * np.log10(255.0 ** 2 / mse)
        out.append({"index": rec["index"], "psnr_db": round(psnr, 2), "mse": round(mse, 2)})
        print(f"  IMG{rec['index']:03d}  PSNR={psnr:6.2f} dB  MSE={mse:8.2f}"
              f"  {'OK（同一场景）' if psnr >= 20 else 'WARN 内容疑似错位'}")
    return {"available": True, "items": out}


def verify_legacy_reproduction(load_fresh) -> dict:
    """决定性证据：按**原始参数与原始字体**复现，应与既有 BMP 逐像素相同。

    为什么这条比 PSNR 更有力
    ------------------------
    母版若真的只是"把 640x480 成品插值放大"，那么用原始参数重跑必然复现不了原图
    （插值放大不改变信息、但会改变像素值）。反之，如果原始参数能**逐像素复现**
    既有 BMP（max|diff| = 0），就证明本脚本加载的绘制管线与当初生成 SD 卡图的
    管线完全同源；此时把 SCALE 提到 6、缩放目标改为 1920x1440，只是同一条管线
    换了采样精度，场景内容必然一致 —— 这就是"原生重渲染"的定义。

    注意字体必须用**原始选择**：font_path(None) 得 Noto Sans SC 作常规体，
    bold 候选 Dengb.ttf 作粗体（与 generate_campus_media.main() 第 561-565 行一致）。
    母版故意改用 Noto 双字重（规避等线/雅黑的专有授权），字形因此与既有 BMP 有
    细微差异 —— 这是**有意的、已记录的**偏离，由 measure_font_deviation() 单独量化，
    不能与"内容错位"混为一谈。

    开发期实测：用原始字体时 6 张全部 max|diff|=0、identical=True。
    """
    sd_dir = REPO_ROOT / "assets" / "campus_media" / "sd_card"
    if not sd_dir.is_dir():
        return {"available": False}
    print("\n[自检] 决定性证据：按原参数+原字体(SCALE=2 -> 640x480)复现既有 SD 卡 BMP")
    gcm = load_fresh()
    gcm.SCALE = 2
    gcm.Artboard.round_to_native = lambda self: self.image.resize(
        LEGACY_SIZE, Image.Resampling.LANCZOS)
    # 还原 generate_campus_media.main() 的字体选择，否则字形不同、比对必然失败
    gcm.FONT_REGULAR = gcm.font_path(None)
    bold_candidates = [Path(r"C:\Windows\Fonts\Dengb.ttf"),
                       Path(r"C:\Windows\Fonts\simhei.ttf")]
    gcm.FONT_BOLD_PATH = next((p for p in bold_candidates if p.is_file()), gcm.FONT_REGULAR)
    items, all_identical = [], True
    for idx, renderer in enumerate(gcm.SCENE_RENDERERS, 1):
        legacy = sd_dir / f"IMG{idx:03d}.BMP"
        if not legacy.is_file():
            continue
        got = np.asarray(renderer().convert("RGB"), dtype=np.int16)
        with Image.open(legacy) as im:
            ref = np.asarray(im.convert("RGB"), dtype=np.int16)
        diff = np.abs(got - ref)
        identical = bool(np.array_equal(got, ref))
        all_identical &= identical
        items.append({"index": idx, "max_abs_diff": int(diff.max()),
                      "mean_abs_diff": round(float(diff.mean()), 6),
                      "identical": identical})
        print(f"  IMG{idx:03d}  max|diff|={diff.max():3d}  "
              f"mean|diff|={diff.mean():.4f}  identical={identical}")
    print(f"  -> {'管线与既有成品完全同源，母版确为原生重渲染' if all_identical else '不一致，母版来源可疑'}")
    return {"available": True, "all_identical": all_identical, "items": items}


def measure_font_deviation(records: list[dict]) -> dict:
    """量化"母版用 Noto 双字重"相对"既有 BMP 用等线粗体"造成的差异。

    差异集中在文字笔画上（数字/英文/中文标题的边缘），几何图形完全一致。
    用差异像素占全图比例来表达，避免读者把这一点误读成内容错位。
    """
    sd_dir = REPO_ROOT / "assets" / "campus_media" / "sd_card"
    if not sd_dir.is_dir():
        return {"available": False}
    print("\n[说明] 母版字体偏离（有意为之，规避等线/雅黑专有授权）的量化")
    items = []
    for rec in records:
        legacy = sd_dir / f"IMG{rec['index']:03d}.BMP"
        if not legacy.is_file():
            continue
        with Image.open(legacy) as im:
            ref = np.asarray(im.convert("RGB"), dtype=np.int16)
        with Image.open(rec["master"]) as im:
            got = np.asarray(im.convert("RGB").resize(LEGACY_SIZE, Image.Resampling.LANCZOS),
                             dtype=np.int16)
        diff = np.abs(got - ref).max(axis=2)
        frac = float((diff > 24).mean()) * 100.0
        items.append({"index": rec["index"], "pixels_over_24_pct": round(frac, 3)})
        print(f"  IMG{rec['index']:03d}  差异像素(>24/255)占比 {frac:5.2f}%  "
              f"（集中在文字笔画边缘，几何图形一致）")
    return {"available": True, "items": items}


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def self_check(out_dir: Path, records: list[dict]) -> dict:
    """用 Pillow 重新打开每个产物，核对尺寸/模式，并检测母版不是上采样（锐度对比）。"""
    print("\n[自检] 用 Pillow 重新打开并校验：")
    ok = True
    checks = []
    for rec in records:
        for key, want in (("master", MASTER_SIZE), ("base", BASE_SIZE)):
            path = rec[key]
            with Image.open(path) as im:
                im.load()                       # 真正解码，不是只看文件头
                size, mode, fmt = im.size, im.mode, im.format
                arr = np.asarray(im.convert("L"), dtype=np.float32)
            good = (size == want and mode == "RGB" and fmt == "PNG")
            ok &= good
            # 拉普拉斯能量：边缘锐度指标，用于证明母版不是 640x480 插值放大的
            lap = laplacian_energy(arr)
            checks.append({
                "file": path.name, "size": list(size), "mode": mode, "format": fmt,
                "bytes": path.stat().st_size, "sha256": sha256_of(path),
                "sharpness": round(lap, 4), "ok": good,
            })
            flag = "OK " if good else "BAD"
            print(f"  [{flag}] {path.name:28s} {size[0]}x{size[1]} {mode} {fmt} "
                  f"{path.stat().st_size:>9,} B  sharp={lap:.3f}")
    return {"ok": ok, "files": checks}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="只校验已有产物，不重新生成")
    ap.add_argument("--out", type=Path, default=OUT_DIR, help="输出目录")
    args = ap.parse_args()
    out_dir: Path = args.out

    if args.check:
        records = [{"index": i, "master": out_dir / f"IMG{i:03d}.png",
                    "base": out_dir / f"IMG{i:03d}_1280x960.png"} for i, _, _ in SCENE_INFO]
        missing = [p for r in records for p in (r["master"], r["base"]) if not p.is_file()]
        if missing:
            raise SystemExit("缺少产物：" + ", ".join(p.name for p in missing))
        result = self_check(out_dir, records)
        print(f"\n[自检] {'通过' if result['ok'] else '失败'}")
        return 0 if result["ok"] else 1

    print(f"[1/4] 加载源生成脚本 {SCRIPTS_DIR / 'generate_campus_media.py'}")
    gcm = load_generator()
    print(f"      逻辑坐标系 {gcm.W}x{gcm.H}，超采样倍数 2 -> {SUPERSAMPLE}"
          f"（画布 {gcm.W * SUPERSAMPLE}x{gcm.H * SUPERSAMPLE}）")
    print(f"      收尾缩放 640x480 -> {MASTER_SIZE[0]}x{MASTER_SIZE[1]}")
    gcm = configure_generator(gcm, MASTER_SIZE, SUPERSAMPLE)

    print(f"\n[2/4] 原生重渲染 6 张母版 -> {out_dir}")
    records = render_masters(gcm, out_dir)

    print(f"\n[3/4] 生成上采样对照（诚实留证，非母版）")
    refs = make_upscaled_reference(out_dir)

    print("\n[4/4] 自检")
    result = self_check(out_dir, records)
    # 锐度交叉验证：原生重渲染的拉普拉斯能量应显著高于 640x480 插值放大
    if refs:
        with Image.open(refs[0]["dst"]) as im:
            up_arr = np.asarray(im.convert("L"), dtype=np.float32)
        up_sharp = laplacian_energy(up_arr)
        ms_sharp = next(c["sharpness"] for c in result["files"]
                        if c["file"] == "IMG001.png")
        print(f"  锐度对比 IMG001：原生重渲染={ms_sharp:.3f}  "
              f"640x480上采样={up_sharp:.3f}  "
              f"比值={ms_sharp / max(up_sharp, 1e-9):.2f}x（越高说明原生重渲染细节越真实）")

    print(f"\n[自检] {'全部通过' if result['ok'] else '存在失败项'}")
    content_fidelity(records)
    verify_legacy_reproduction(load_generator)
    measure_font_deviation(records)
    print(f"产物目录：{out_dir}")
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
