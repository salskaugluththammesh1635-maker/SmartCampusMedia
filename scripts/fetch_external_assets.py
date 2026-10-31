#!/usr/bin/env python3
"""Fetch openly licensed campus/technology media for the SmartCampusMedia gallery.

Two asset classes are produced:

* Images: downloaded from Wikimedia Commons, cropped to 4:3, resized to 640x480
  and written as 24-bit BI_RGB BMP so the FPGA player can read them straight off
  a FAT32 SD-card root (IMG001.BMP, IMG002.BMP, ...).
* Videos: the 640 px MP4 transcode of a Commons clip plus sampled still frames.
  The FPGA never decodes video; clips are for the PC/browser demo reel only.

Every downloaded item is recorded in ``assets/external/ATTRIBUTION.md`` together
with its author, license and source URL, because most Commons media is CC BY or
CC BY-SA and requires attribution when shown publicly.

Requires Python 3 and Pillow. OpenCV is only needed for the video branch.

Usage::

    python scripts\\fetch_external_assets.py                 # images + videos
    python scripts\\fetch_external_assets.py --images-only
    python scripts\\fetch_external_assets.py --list           # show the catalogue
    python scripts\\fetch_external_assets.py --only smart_campus
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT_ROOT = ROOT / "assets" / "external"
IMG_DIR = OUT_ROOT / "sd_card"
PREVIEW_DIR = OUT_ROOT / "preview"
VIDEO_DIR = OUT_ROOT / "video"
FRAME_DIR = OUT_ROOT / "video_frames"

W, H = 640, 480
API = "https://commons.wikimedia.org/w/api.php"
UA = "SmartCampusMediaAssetFetcher/1.0 (student FPGA competition project; educational use)"


@dataclass
class Candidate:
    """One curated asset, keyed by its exact Commons file title."""

    title: str
    theme: str
    caption: str
    kind: str = "image"  # "image" | "video"
    tags: list[str] = field(default_factory=list)


# Titles were selected by hand from Commons search results: landscape framing,
# enough resolution to survive a 640x480 crop, and a license that allows reuse.
CATALOGUE: list[Candidate] = [
    # --- 智慧校园 / 信息发布终端 -------------------------------------------
    Candidate("File:Narita Terminal 2 Arrivals Lobby B information screen 2023-06-30.jpg",
              "smart_campus", "机场信息发布屏：多行航班信息的实际部署形态", tags=["signage", "screen"]),
    Candidate("File:Knams-15-knsq-5.jpg", "smart_campus",
              "机房服务器机柜：信息发布终端的后台一侧", tags=["server", "network"]),
    Candidate("File:UC Syd, CCTV camera.jpg", "smart_campus",
              "校园监控摄像机：平安校园感知层的末端节点", tags=["cctv", "safety"]),
    # --- 书香校园 / 图书馆 --------------------------------------------------
    Candidate("File:Mansueto Library reading room.JPG", "library",
              "大学图书馆阅览室：安静阅读的公共空间", tags=["library", "reading"]),
    Candidate("File:Interior of the Hutzler Reading room located in Gilman Hall, on the Johns Hopkins University campus in Baltimore, Maryland LCCN2013646482.tif",
              "library", "拱顶阅览室：古典图书馆的空间气质", tags=["library", "architecture"]),
    Candidate("File:Chittenden Library and Reading Room Yale University.jpg", "library",
              "耶鲁大学阅览室：书架与长桌的阅读场景", tags=["library", "books"]),
    # --- 创客工坊 / FPGA 实验室 --------------------------------------------
    Candidate("File:Electronics workbench.jpg", "maker",
              "电子工作台：调试仪器与手边工具", tags=["lab", "workbench"]),
    Candidate("File:Macro circuit board.JPG", "maker",
              "电路板微距：走线与焊点的细节", tags=["pcb", "macro"]),
    Candidate("File:Keysight InfiniiVision DSOX 4024A and digital multimeter and power supply in laboratory use.jpg",
              "maker", "示波器与万用表：数字系统调试的常用组合", tags=["oscilloscope", "lab"]),
    Candidate("File:FPGARetrocomputing.jpg", "maker",
              "FPGA 芯片与外围器件：可编程逻辑的物理形态", tags=["fpga", "chip"]),
    # --- 绿色校园 ----------------------------------------------------------
    Candidate("File:Distant View of Campus Field.jpg", "green",
              "校园草坪远景：开阔的绿色空间", tags=["campus", "lawn"]),
    Candidate("File:Solar panels on car parking.jpg", "green",
              "停车场光伏顶棚：校园清洁能源的一种落地方式", tags=["solar", "energy"]),
    Candidate("File:Bicycles on the campus of Harvard University.JPG", "green",
              "校园自行车停放区：低碳出行的日常", tags=["bicycle", "campus"]),
    # --- 运动嘉年华 --------------------------------------------------------
    Candidate("File:Keele University, sports field and running track - geograph.org.uk - 4352965.jpg",
              "sports", "大学田径场：跑道与看台", tags=["track", "sports"]),
    Candidate("File:HSNU Sports Field 01 20250823.jpg", "sports",
              "校园运动场：球场与围网", tags=["field", "sports"]),
    # --- 平安校园 ----------------------------------------------------------
    Candidate("File:Outdoor cctv (Unsplash).jpg", "safety",
              "户外监控摄像机：校园周界的常规布点", tags=["cctv", "outdoor"]),
    Candidate("File:Emergency exit UK 005.jpg", "safety",
              "应急出口指示：高优先级提示的视觉参照", tags=["exit", "sign"]),
    # --- 接口与介质（技术演示页）------------------------------------------
    Candidate("File:HDMI CableEnd.jpg", "tech",
              "HDMI 接口特写：本项目唯一的视频输出通道", tags=["hdmi", "connector"]),
    Candidate("File:Size comparison of SD card, microSD card, and dime.jpg", "tech",
              "SD 卡尺寸对比：图库素材的存储介质", tags=["sd", "storage"]),
    Candidate("File:SDHC memory card - 8GB.jpeg", "tech",
              "SDHC 存储卡：FAT32 卷与 IMG00x.BMP 的载体", tags=["sd", "storage"]),
    # --- 视频（仅用于 PC 演示，FPGA 不解码）--------------------------------
    Candidate("File:Linnanmaa University of Oulu 20260118.webm", "video_campus",
              "奥卢大学校园漫步（CC0）：可直接用于演示片头", kind="video", tags=["campus", "walk"]),
    Candidate("File:GDUFS Timelapse 2014.webm", "video_campus",
              "广东外语外贸大学延时：校园昼夜变化", kind="video", tags=["campus", "timelapse"]),
    Candidate("File:University of Oklahoma- In Motion - 4K Timelapse Video.webm", "video_campus",
              "俄克拉荷马大学 4K 延时：建筑与人流", kind="video", tags=["campus", "timelapse"]),
    Candidate("File:Gas sensor with Arduino.webm", "video_lab",
              "电子制作过程实拍：面包板与传感器接线", kind="video", tags=["lab", "electronics"]),
]


# --------------------------------------------------------------------------- API


def _api(params: dict) -> dict:
    url = f"{API}?{urllib.parse.urlencode(params)}"
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except Exception:
            if attempt == 3:
                raise
            time.sleep(3 * (attempt + 1))
    raise RuntimeError("unreachable")


def _strip_html(value: str) -> str:
    """Commons artist fields contain HTML; keep the readable text only."""
    out, depth = [], 0
    for ch in value:
        if ch == "<":
            depth += 1
        elif ch == ">":
            depth = max(0, depth - 1)
        elif depth == 0:
            out.append(ch)
    return " ".join("".join(out).split())


def fetch_metadata(titles: list[str], kind: str) -> dict[str, dict]:
    """Return {title: {url, width, height, license, artist, page}} for each title."""
    meta: dict[str, dict] = {}
    prop = "videoinfo" if kind == "video" else "imageinfo"
    for start in range(0, len(titles), 10):
        batch = titles[start : start + 10]
        params = {
            "action": "query",
            "format": "json",
            "titles": "|".join(batch),
            "prop": prop,
        }
        if kind == "video":
            params["viprop"] = "url|size|derivatives|extmetadata"
        else:
            params["iiprop"] = "url|size|extmetadata"
            params["iiurlwidth"] = "1600"
        data = _api(params)
        for page in data.get("query", {}).get("pages", {}).values():
            title = page.get("title", "")
            info = page.get(prop)
            if not info:
                continue
            info = info[0]
            em = info.get("extmetadata", {})
            entry = {
                "width": info.get("width", 0),
                "height": info.get("height", 0),
                "license": em.get("LicenseShortName", {}).get("value", "unknown"),
                "license_url": em.get("LicenseUrl", {}).get("value", ""),
                "artist": _strip_html(str(em.get("Artist", {}).get("value", "unknown")))[:120],
                "page": info.get("descriptionurl", ""),
            }
            if kind == "video":
                mp4 = [
                    d for d in info.get("derivatives", [])
                    if d.get("width") == 640 and "mp4" in (d.get("type") or "")
                ]
                entry["url"] = mp4[0]["src"] if mp4 else info.get("url", "")
            else:
                entry["url"] = info.get("thumburl", info.get("url", ""))
            meta[title] = entry
    return meta


def download(url: str, dest: Path, retries: int = 3) -> int:
    dest.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=180) as resp, open(dest, "wb") as fh:
                fh.write(resp.read())
            return dest.stat().st_size
        except Exception:
            if attempt == retries - 1:
                raise
            time.sleep(4 * (attempt + 1))
    raise RuntimeError("unreachable")


# ----------------------------------------------------------------------- images


def cover_crop(image: Image.Image, size: tuple[int, int] = (W, H)) -> Image.Image:
    """Centre-crop to the target aspect ratio, then resize with Lanczos."""
    tw, th = size
    src_ratio = image.width / image.height
    dst_ratio = tw / th
    if src_ratio > dst_ratio:
        new_w = round(image.height * dst_ratio)
        left = (image.width - new_w) // 2
        image = image.crop((left, 0, left + new_w, image.height))
    elif src_ratio < dst_ratio:
        new_h = round(image.width / dst_ratio)
        top = (image.height - new_h) // 2
        image = image.crop((0, top, image.width, top + new_h))
    return image.resize((tw, th), Image.Resampling.LANCZOS)


def save_bmp24(image: Image.Image, path: Path) -> None:
    """Write a 24-bit BI_RGB BMP and verify the header the FPGA parser expects."""
    image.convert("RGB").save(path, format="BMP")
    header = path.read_bytes()[:54]
    if len(header) != 54:
        raise RuntimeError(f"Invalid BMP header: {path}")
    sig, size, _, offset, dib, width, height, planes, depth, compression = struct.unpack(
        "<2sI I I I i i H H I", header[:34]
    )
    if (sig, size, offset, dib, width, abs(height), planes, depth, compression) != (
        b"BM", path.stat().st_size, 54, 40, W, H, 1, 24, 0
    ):
        raise RuntimeError(f"BMP does not match the player's expected 24-bit BI_RGB format: {path}")


def _font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    for candidate in (
        r"C:\Windows\Fonts\NotoSansSC-VF.ttf",
        r"C:\Windows\Fonts\Dengb.ttf",
        r"C:\Windows\Fonts\msyh.ttc",
        r"C:\Windows\Fonts\simhei.ttf",
    ):
        if Path(candidate).is_file():
            return ImageFont.truetype(candidate, size)
    return ImageFont.load_default()


def build_contact_sheet(entries: list[dict], path: Path) -> None:
    cols, cell_w, cell_h, pad, label_h = 4, 300, 225, 16, 34
    rows = (len(entries) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * (cell_w + pad) + pad, rows * (cell_h + label_h + pad) + pad), (16, 26, 38))
    draw = ImageDraw.Draw(sheet)
    font = _font(15)
    for idx, entry in enumerate(entries):
        col, row = idx % cols, idx // cols
        x = pad + col * (cell_w + pad)
        y = pad + row * (cell_h + label_h + pad)
        with Image.open(entry["preview"]) as im:
            sheet.paste(im.convert("RGB").resize((cell_w, cell_h), Image.Resampling.LANCZOS), (x, y))
        draw.text((x + 2, y + cell_h + 8), f"{entry['bmp'].name}  {entry['theme']}", font=font, fill=(196, 216, 228))
    sheet.save(path, format="PNG")


def run_images(only: set[str] | None) -> list[dict]:
    picks = [c for c in CATALOGUE if c.kind == "image" and (not only or c.theme in only)]
    if not picks:
        return []
    meta = fetch_metadata([c.title for c in picks], "image")
    # Drop unusable entries *before* numbering: gallery_probe on the FPGA stops at
    # the first missing index, so IMG001.BMP must form an unbroken run.
    usable: list[tuple[Candidate, dict]] = []
    for cand in picks:
        info = meta.get(cand.title)
        if not info or not info.get("url"):
            print(f"  [skip] metadata missing: {cand.title}")
            continue
        if info["width"] < W or info["height"] < H:
            print(f"  [skip] too small ({info['width']}x{info['height']}): {cand.title}")
            continue
        usable.append((cand, info))
    IMG_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    raw_dir = OUT_ROOT / "raw"
    entries: list[dict] = []
    for cand, info in usable:
        index = len(entries) + 1  # numbering follows successes only: no gaps
        raw = raw_dir / f"src_{index:03d}.jpg"
        try:
            size = download(info["url"], raw)
        except Exception as exc:  # network hiccup: keep going, report at the end
            print(f"  [fail] download {cand.title}: {exc}")
            continue
        with Image.open(raw) as im:
            frame = cover_crop(im.convert("RGB"))
        bmp = IMG_DIR / f"IMG{index:03d}.BMP"
        save_bmp24(frame, bmp)
        preview = PREVIEW_DIR / f"IMG{index:03d}.png"
        frame.save(preview, format="PNG")
        entries.append({
            "bmp": bmp,
            "preview": preview,
            "theme": cand.theme,
            "caption": cand.caption,
            "tags": cand.tags,
            "title": cand.title,
            "source": info["page"],
            "artist": info["artist"],
            "license": info["license"],
            "license_url": info["license_url"],
            "source_bytes": size,
        })
        print(f"  [ok] {bmp.name}  {cand.theme:<12} {info['license']:<14} {cand.title[5:60]}")
        raw.unlink(missing_ok=True)
    if entries:
        build_contact_sheet(entries, PREVIEW_DIR / "contact_sheet.png")
        print(f"  contact sheet -> {PREVIEW_DIR / 'contact_sheet.png'}")
    return entries


# ----------------------------------------------------------------------- videos


def run_videos(only: set[str] | None) -> list[dict]:
    picks = [c for c in CATALOGUE if c.kind == "video" and (not only or c.theme in only)]
    if not picks:
        return []
    try:
        import cv2  # noqa: PLC0415  (optional dependency, imported lazily)
    except ImportError:
        print("  [skip] OpenCV not installed: pip install opencv-python")
        return []
    meta = fetch_metadata([c.title for c in picks], "video")
    VIDEO_DIR.mkdir(parents=True, exist_ok=True)
    FRAME_DIR.mkdir(parents=True, exist_ok=True)
    entries: list[dict] = []
    for cand in picks:
        info = meta.get(cand.title)
        if not info or not info.get("url"):
            print(f"  [skip] no 640px MP4 transcode: {cand.title}")
            continue
        index = len(entries) + 1  # numbering follows successes only: no gaps
        dest = VIDEO_DIR / f"CLIP{index:02d}.mp4"
        try:
            size = download(info["url"], dest)
        except Exception as exc:
            print(f"  [fail] download {cand.title}: {exc}")
            continue
        cap = cv2.VideoCapture(str(dest))
        if not cap.isOpened():
            print(f"  [fail] OpenCV cannot decode {dest.name}")
            cap.release()
            continue
        total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
        fps = cap.get(cv2.CAP_PROP_FPS) or 25.0
        frames = []
        for slot in range(6):
            pos = int(total * (slot + 0.5) / 6)
            cap.set(cv2.CAP_PROP_POS_FRAMES, pos)
            ok, frame = cap.read()
            if not ok:
                continue
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            still = cover_crop(Image.fromarray(rgb))
            path = FRAME_DIR / f"CLIP{index:02d}_F{slot + 1}.BMP"
            save_bmp24(still, path)
            frames.append(path)
        cap.release()
        entries.append({
            "clip": dest,
            "frames": frames,
            "theme": cand.theme,
            "caption": cand.caption,
            "tags": cand.tags,
            "title": cand.title,
            "source": info["page"],
            "artist": info["artist"],
            "license": info["license"],
            "license_url": info["license_url"],
            "seconds": round(total / fps, 1) if fps else 0,
            "source_bytes": size,
        })
        print(f"  [ok] {dest.name}  {info['license']:<14} {total} frames @ {fps:.0f} fps -> {len(frames)} stills")
    return entries


# --------------------------------------------------------------------- reports


def write_attribution(images: list[dict], videos: list[dict]) -> None:
    lines = [
        "# 外部素材署名清单（external assets）",
        "",
        "> 本文件由 `scripts/fetch_external_assets.py` 自动生成，请勿手工编辑。",
        "> 所有素材来自 Wikimedia Commons，均为可再利用许可；**公开演示、答辩 PPT 与视频中必须保留下列署名**。",
        "> CC BY-SA 素材还带有「相同方式共享」义务：以其为基础制作的衍生画面，需要以同样许可发布。",
        "",
        "## 一、图片（已转 640×480 24 bit BI_RGB BMP）",
        "",
        "| 文件 | 主题 | 内容 | 作者 | 许可 | 来源 |",
        "|---|---|---|---|---|---|",
    ]
    for e in images:
        lic = e["license"] + (f"（[文本]({e['license_url']})）" if e["license_url"] else "")
        lines.append(
            f"| `{e['bmp'].name}` | {e['theme']} | {e['caption']} | {e['artist']} | {lic} | "
            f"[Commons]({e['source']}) |"
        )
    lines += ["", "## 二、视频（PC 演示用，FPGA 不解码）", "",
              "| 文件 | 主题 | 内容 | 时长 | 作者 | 许可 | 来源 |", "|---|---|---|---|---|---|---|"]
    for e in videos:
        lic = e["license"] + (f"（[文本]({e['license_url']})）" if e["license_url"] else "")
        lines.append(
            f"| `{e['clip'].name}` | {e['theme']} | {e['caption']} | {e['seconds']} s | {e['artist']} | "
            f"{lic} | [Commons]({e['source']}) |"
        )
    lines += ["", "## 三、原始文件标题", ""]
    for e in images + videos:
        lines.append(f"- `{e['title']}`")
    (OUT_ROOT / "ATTRIBUTION.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_manifest(images: list[dict], videos: list[dict]) -> None:
    payload = {
        "generator": "scripts/fetch_external_assets.py",
        "source": "Wikimedia Commons",
        "image_format": "640x480 24-bit BI_RGB BMP",
        "images": [
            {
                "file": f"sd_card/{e['bmp'].name}",
                "preview": f"preview/{e['preview'].name}",
                "theme": e["theme"],
                "caption": e["caption"],
                "tags": e["tags"],
                "title": e["title"],
                "author": e["artist"],
                "license": e["license"],
                "license_url": e["license_url"],
                "source": e["source"],
                "bytes": e["bmp"].stat().st_size,
            }
            for e in images
        ],
        "videos": [
            {
                "file": f"video/{e['clip'].name}",
                "frames": [f"video_frames/{f.name}" for f in e["frames"]],
                "theme": e["theme"],
                "caption": e["caption"],
                "tags": e["tags"],
                "title": e["title"],
                "author": e["artist"],
                "license": e["license"],
                "license_url": e["license_url"],
                "source": e["source"],
                "seconds": e["seconds"],
                "bytes": e["clip"].stat().st_size,
            }
            for e in videos
        ],
    }
    (OUT_ROOT / "manifest.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--images-only", action="store_true", help="Skip the video branch.")
    parser.add_argument("--videos-only", action="store_true", help="Skip the image branch.")
    parser.add_argument("--only", action="append", default=None,
                        help="Restrict to one theme (repeatable), e.g. --only library --only maker.")
    parser.add_argument("--list", action="store_true", help="Print the curated catalogue and exit.")
    args = parser.parse_args()

    if args.list:
        for cand in CATALOGUE:
            print(f"{cand.kind:<6} {cand.theme:<14} {cand.title[5:]}")
        print(f"\n{len(CATALOGUE)} curated assets; themes: "
              f"{', '.join(sorted({c.theme for c in CATALOGUE}))}")
        return 0

    only = set(args.only) if args.only else None
    images: list[dict] = []
    videos: list[dict] = []

    if not args.videos_only:
        print("Images ->", IMG_DIR)
        images = run_images(only)
    if not args.images_only:
        print("Videos ->", VIDEO_DIR)
        videos = run_videos(only)

    OUT_ROOT.mkdir(parents=True, exist_ok=True)
    write_attribution(images, videos)
    write_manifest(images, videos)
    print(f"\nDone: {len(images)} BMP + {len(videos)} clip(s).")
    print(f"Attribution: {OUT_ROOT / 'ATTRIBUTION.md'}")
    print(f"Manifest:    {OUT_ROOT / 'manifest.json'}")
    if images:
        print("Copy assets\\external\\sd_card\\IMG*.BMP to the FAT32 SD-card root to play them.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
