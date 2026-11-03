# 智播校园素材包

这组原创矢量风格校园插画围绕项目的 FPGA 图片图库播放能力制作，包含智慧校园、图书馆、创客工坊、绿色校园、运动嘉年华和平安校园六个主题。插画采用统一的夜蓝、青绿与暖金视觉语言，并保留适合 640×480 屏幕观看的高对比度标题和留白。

## FPGA 图片图库

`sd_card/IMG001.BMP` 至 `IMG006.BMP` 是可直接播放的文件：每张均为 **640×480、24 bit、无压缩 BMP（BI_RGB）**，命名连续，适用于 FAT32 卡根目录。将这六个 BMP 一起复制到 SD 卡根目录即可：

```powershell
Copy-Item assets\campus_media\sd_card\IMG*.BMP E:\
```

将 `E:` 替换为实际 SD 卡盘符。启动后图库会扫描 `IMG001.BMP` 起连续的图片；使用播放器的下一张/上一张操作浏览主题。请只复制 `sd_card` 下的 BMP，不要改名或跳号。

## 短片与预览

- `preview/smart_campus_showcase.mp4`：约 26 秒、1280×720 的无声校园主题展示短片，带轻微推镜与片间淡化，适用于电脑或通用播放器展示。
- `preview/IMG001.png` 至 `IMG006.png`：同款 PNG 图片，可用于文档、演示或网页。
- `preview/contact_sheet.png`：六张图的总览缩略图。

**当前 FPGA 不支持 MP4 等编码视频，也不解码音视频文件。** 短片用于外部演示，放进 SD 卡不能由现有硬件直接播放；FPGA 可播放的是上述静态 BMP 图库。项目音频为 FPGA 根据播放状态生成的提示音。

## 重新生成

需要 Python 3 与 Pillow；生成 MP4 还需要安装 OpenCV：

```powershell
python -m pip install Pillow opencv-python
python scripts\generate_campus_media.py
```

脚本默认使用系统 Noto Sans SC / DengXian / SimHei 字体，可用 `--font <字体路径>` 指定字体；`--skip-video` 只生成 BMP、PNG 和总览图。BMP 头会在写出时自动检查分辨率、位深与压缩格式。
