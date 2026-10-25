# =============================================================================
# make_test_bmps.ps1 — 生成 SD 卡验证用 BMP 测试图
# 用途: 阶段四 SD 卡图片播放链路的素材准备（拷到 SD 卡 FAT32 根目录）
# 生成:
#   IMG001.BMP — 全屏 640x480 七彩竖条（默认单图工程直接使用）
#   IMG002.BMP — 全屏 640x480 白底中央红块（与 IMG001 一起放卡上即可切换）
# 当前 HDMI 顶层只接受 640x480；没有缩放或居中小图的处理路径。
# 格式: BMP 24bit, 底-上行序（biHeight>0 标准 BMP），54 字节文件头 + BGR 像素
# 运行: powershell -ExecutionPolicy Bypass -File scripts\make_test_bmps.ps1
# 输出: assets\sd_images\ 目录
# =============================================================================

$ErrorActionPreference = 'Stop'
$outDir = Join-Path $PSScriptRoot '..\assets\sd_images'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

function Write-Bmp {
    param([string]$Path, [int]$W, [int]$H, [scriptblock]$PixelFn)
    # BMP 文件头 14B + BITMAPINFOHEADER 40B = 54B
    $rowSize = [Math]::Ceiling(($W * 3) / 4) * 4   # 每行 4 字节对齐
    $dataSize = $rowSize * $H
    $fileSize = 54 + $dataSize
    $fs = [System.IO.File]::Create($Path)
    $bw = New-Object System.IO.BinaryWriter($fs)
    # BITMAPFILEHEADER
    $bw.Write([char[]]"BM")
    $bw.Write([UInt32]$fileSize)
    $bw.Write([UInt32]0)
    $bw.Write([UInt32]54)
    # BITMAPINFOHEADER
    $bw.Write([UInt32]40)
    $bw.Write([Int32]$W)
    $bw.Write([Int32]$H)          # 正值 = 底-上行序
    $bw.Write([UInt16]1)
    $bw.Write([UInt16]24)
    $bw.Write([UInt32]0)
    $bw.Write([UInt32]$dataSize)
    $bw.Write([Int32]2835)
    $bw.Write([Int32]2835)
    $bw.Write([UInt32]0)
    $bw.Write([UInt32]0)
    # 像素: BMP 底行先写 → y 从 H-1 递减
    $pad = $rowSize - $W * 3
    $padding = New-Object byte[] $pad
    for ($y = $H - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $W; $x++) {
            $rgb = & $PixelFn $x $y
            $bw.Write([byte]$rgb[2])  # B
            $bw.Write([byte]$rgb[1])  # G
            $bw.Write([byte]$rgb[0])  # R
        }
        if ($pad -gt 0) { $bw.Write($padding) }
    }
    $bw.Flush(); $bw.Close(); $fs.Close()
    "  {0}  ({1}x{2}, {3:N0}B)" -f (Split-Path $Path -Leaf), $W, $H, $fileSize
}

Write-Host "生成 SD 验证图 → $outDir"

# 图 1: 640x480 七彩竖条（红橙黄绿青蓝紫 + 白黑端点）——与 HDMI 测试图案视觉可区分
Write-Bmp -Path (Join-Path $outDir 'IMG001.BMP') -W 640 -H 480 -PixelFn {
    param($x, $y)
    $band = [Math]::Floor($x / 80)   # 640/80 = 8 竖条
    switch ($band) {
        0 { return 255,255,255 }  # 白
        1 { return 255,0,0 }      # 红
        2 { return 255,165,0 }    # 橙
        3 { return 255,255,0 }    # 黄
        4 { return 0,255,0 }      # 绿
        5 { return 0,255,255 }    # 青
        6 { return 0,0,255 }      # 蓝
        default { return 128,0,128 } # 紫
    }
}

# 图 2: 640x480 白底中央 200x200 红块，与第一张有明显区别
Write-Bmp -Path (Join-Path $outDir 'IMG002.BMP') -W 640 -H 480 -PixelFn {
    param($x, $y)
    if ($x -ge 220 -and $x -lt 420 -and $y -ge 140 -and $y -lt 340) { return 255,0,0 }
    return 255,255,255
}

Write-Host "完成。将 IMG001.BMP 与 IMG002.BMP 一起拷到 FAT32 SDHC 卡根目录（MBR 第一分区或 LBA0 直接卷）。"
Write-Host "图库张数上电自动扫描：两张都在时可直接用 KEY1 切到 IMG002，无需改参数或重新综合。"
