# =============================================================================
# prepare_board_verify_assets.ps1 — 生成「上板一次性验证」用的 SD 卡素材
# -----------------------------------------------------------------------------
# 用途: 配合 docs/board_verification_2026-10-27.md 使用。
#       正式顶层 dmz_eg4s20_hdmi_top 从未上板，本脚本把验证流程需要换的
#       几套卡内容一次性生成好，避免现场手工改图/改名出错。
#
# 生成目录（默认 assets\sd_verify\）:
#   good\        IMG001~IMG006.BMP   正常播放 + 换图 + 轮播的最小素材集
#   bad_size\    IMG001 正常 + IMG002 320x240 → 期望数码管显示 b1（BMP 宽高不符）
#   bad_bmp\     IMG001 正常 + IMG002 非 "BM" 签名 → 期望数码管显示 b1（签名错）
#   empty\       只有说明文件，没有任何 IMGnnn.BMP → 期望数码管显示 00（零张图）
#
# 为什么坏图放在独立目录、并且仍然叫 IMG002.BMP:
#   gallery_probe 只认「从 IMG001 开始连续不间断」的短名（见 rtl/storage/
#   fat32_reader.v 错误码表与 gallery_probe.v 文件头）。要测装载失败，
#   必须让坏图落在连续区间的第 2 位，否则扫描阶段就会截断，根本走不到装载。
#
# 图片规格（与 bmp_parser 的硬性要求一致）:
#   640x480、24bit、无压缩、biHeight>0（底上行序）、无行填充（1920 字节整除 4）
#
# 运行: powershell -ExecutionPolicy Bypass -File scripts\prepare_board_verify_assets.ps1
#       可选 -OutRoot <目录> 覆盖输出根目录
#
# 注意: assets\sd_verify\ 已被 .gitignore 忽略 —— 素材由本脚本现场生成，
#       不入库（避免仓库里堆十几 MB 的 BMP）。
# =============================================================================

[CmdletBinding()]
param(
    [string]$OutRoot = ''
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutRoot)) {
    $OutRoot = Join-Path $repoRoot 'assets\sd_verify'
}

# -----------------------------------------------------------------------------
# 工具 1: 在像素缓冲里填一个实心矩形
#   Buf     : [byte[]] 像素缓冲（BGR 顺序，底行先存）
#   Stride  : 每行字节数（含 4 字节对齐填充）
#   坐标系  : (X0,Y0) 为**画面左上角**起算，函数内部再翻成 BMP 的底上行序
# -----------------------------------------------------------------------------
function Add-Rect {
    param(
        [byte[]]$Buf, [int]$Stride, [int]$ImgW, [int]$ImgH,
        [int]$X0, [int]$Y0, [int]$RW, [int]$RH,
        [byte]$Cr, [byte]$Cg, [byte]$Cb
    )
    if ($RW -le 0 -or $RH -le 0) { return }
    $x1 = [Math]::Min($X0 + $RW, $ImgW)
    $y1 = [Math]::Min($Y0 + $RH, $ImgH)
    if ($X0 -ge $x1 -or $Y0 -ge $y1) { return }

    $n = $x1 - $X0
    $line = New-Object byte[] ($n * 3)
    for ($i = 0; $i -lt $n; $i++) {
        $line[$i * 3]     = $Cb
        $line[$i * 3 + 1] = $Cg
        $line[$i * 3 + 2] = $Cr
    }
    for ($y = $Y0; $y -lt $y1; $y++) {
        [Array]::Copy($line, 0, $Buf, ($ImgH - 1 - $y) * $Stride + $X0 * 3, $n * 3)
    }
}

# -----------------------------------------------------------------------------
# 工具 2: 画一个 7 段样式的大数字
#   为什么不用字体: 生成 BMP 只能逐像素写，没有字体渲染；7 段样式用 7 个矩形
#   就能拼出 1~6，而且形状与 FPGA 板上数码管（seg_decoder）语义一致，
#   现场对照「屏上是几」与「数码管显示几」时不会看错。
# -----------------------------------------------------------------------------
function Add-Digit {
    param(
        [byte[]]$Buf, [int]$Stride, [int]$ImgW, [int]$ImgH,
        [int]$Digit, [int]$X0, [int]$Y0, [int]$DW, [int]$DH, [int]$T,
        [byte]$Cr, [byte]$Cg, [byte]$Cb
    )
    $half = [int]($DH / 2)
    $seg = @{}
    $seg['a'] = @(($X0 + $T),               $Y0,                          ($DW - 2 * $T), $T)
    $seg['b'] = @(($X0 + $DW - $T),         ($Y0 + $T),                   $T,             ($half - $T))
    $seg['c'] = @(($X0 + $DW - $T),         ($Y0 + $half),                $T,             ($half - $T))
    $seg['d'] = @(($X0 + $T),               ($Y0 + $DH - $T),             ($DW - 2 * $T), $T)
    $seg['e'] = @($X0,                      ($Y0 + $half),                $T,             ($half - $T))
    $seg['f'] = @($X0,                      ($Y0 + $T),                   $T,             ($half - $T))
    $seg['g'] = @(($X0 + $T),               ($Y0 + $half - [int]($T / 2)), ($DW - 2 * $T), $T)

    # 标准 7 段编码（与 seg_decoder.v 的 0~9 段码表同源）
    $map = @{
        0 = 'abcdef'; 1 = 'bc';     2 = 'abged';  3 = 'abgcd'
        4 = 'fgbc';   5 = 'afgcd';  6 = 'afgecd'; 7 = 'abc'
        8 = 'abcdefg'; 9 = 'abcdfg'
    }
    if (-not $map.ContainsKey($Digit)) { return }
    $on = $map[$Digit]

    foreach ($k in @('a', 'b', 'c', 'd', 'e', 'f', 'g')) {
        if ($on.Contains($k)) {
            $r = $seg[$k]
            Add-Rect -Buf $Buf -Stride $Stride -ImgW $ImgW -ImgH $ImgH `
                     -X0 ([int]$r[0]) -Y0 ([int]$r[1]) -RW ([int]$r[2]) -RH ([int]$r[3]) `
                     -Cr $Cr -Cg $Cg -Cb $Cb
        }
    }
}

# -----------------------------------------------------------------------------
# 工具 3: 写标准 24bit 未压缩 BMP
# -----------------------------------------------------------------------------
function Save-Bmp24 {
    param([string]$Path, [int]$ImgW, [int]$ImgH, [byte[]]$Pixels, [int]$Stride)
    $dataSize = $Stride * $ImgH
    $fileSize = 54 + $dataSize

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    # BITMAPFILEHEADER (14 B)
    $bw.Write([byte]0x42); $bw.Write([byte]0x4D)        # 'B' 'M'
    $bw.Write([uint32]$fileSize)
    $bw.Write([uint32]0)                                 # bfReserved1+2
    $bw.Write([uint32]54)                                # bfOffBits
    # BITMAPINFOHEADER (40 B)
    $bw.Write([uint32]40)
    $bw.Write([int32]$ImgW)
    $bw.Write([int32]$ImgH)                              # 正值 = 底上行序
    $bw.Write([uint16]1)
    $bw.Write([uint16]24)
    $bw.Write([uint32]0)                                 # BI_RGB 无压缩
    $bw.Write([uint32]$dataSize)
    $bw.Write([int32]2835)                               # 72 DPI
    $bw.Write([int32]2835)
    $bw.Write([uint32]0)
    $bw.Write([uint32]0)
    $bw.Write($Pixels)
    $bw.Flush()
    $bytes = $ms.ToArray()
    [System.IO.File]::WriteAllBytes($Path, $bytes)
    $bw.Dispose(); $ms.Dispose()
    return $bytes.Length
}

# -----------------------------------------------------------------------------
# 工具 4: 计算 4 字节对齐后的行字节数（24bit）
#   640*3 = 1920 → 已对齐；320*3 = 960 → 已对齐。
#   本脚本所有尺寸都整除 4，但保留通用算法，将来改尺寸不会静默出错。
# -----------------------------------------------------------------------------
function Get-Stride24 {
    param([int]$ImgW)
    $s = $ImgW * 3
    $r = $s % 4
    if ($r -ne 0) { $s += (4 - $r) }
    return $s
}

# -----------------------------------------------------------------------------
# 工具 5: 生成一张 640x480 的「可辨识序号图」
#   画面构成（从上到下 / 从左到右）:
#     · 整幅背景: 该图专属色（第 N 张用第 N 种色，便于口头描述"现在是紫的"）
#     · 上沿 40px 白条 + 下沿 40px 白条: 用来判断画面有没有被上下裁切
#     · 左沿 40px 白条 + 右沿 40px 白条: 判断左右是否完整（640 全宽）
#     · 中央 360x300 白底圆角框（用白矩形近似）+ 框内黑色 7 段大数字 N
#     · 右下角 N 个白色小方块: 不数数字也能靠方块数确认序号
#   为什么加边框: 上板最容易出的问题就是分辨率/时序偏移导致画面被裁，
#   有 40px 白边就能一眼看出是"整幅偏移"还是"边缘丢失"。
# -----------------------------------------------------------------------------
function New-IndexImage {
    param(
        [string]$Path,
        [int]$Index,
        [int]$BgR, [int]$BgG, [int]$BgB
    )
    $W = 640; $H = 480
    $stride = Get-Stride24 -ImgW $W
    $buf = New-Object byte[] ($stride * $H)

    # ① 全幅背景
    Add-Rect -Buf $buf -Stride $stride -ImgW $W -ImgH $H `
             -X0 0 -Y0 0 -RW $W -RH $H -Cr $BgR -Cg $BgG -Cb $BgB

    # ② 四条白边（宽 40px）
    Add-Rect -Buf $buf -Stride $stride -ImgW $W -ImgH $H -X0 0   -Y0 0   -RW $W -RH 40 -Cr 255 -Cg 255 -Cb 255
    Add-Rect -Buf $buf -Stride $stride -ImgW $W -ImgH $H -X0 0   -Y0 440 -RW $W -RH 40 -Cr 255 -Cg 255 -Cb 255
    Add-Rect -Buf $buf -Stride $stride -ImgW $W -ImgH $H -X0 0   -Y0 0   -RW 40 -RH $H -Cr 255 -Cg 255 -Cb 255
    Add-Rect -Buf $buf -Stride $stride -ImgW $W -ImgH $H -X0 600 -Y0 0   -RW 40 -RH $H -Cr 255 -Cg 255 -Cb 255

    # ③ 中央白底框 360x300（居中: x=140..500, y=90..390）
    Add-Rect -Buf $buf -Stride $stride -ImgW $W -ImgH $H -X0 140 -Y0 90 -RW 360 -RH 300 -Cr 255 -Cg 255 -Cb 255

    # ④ 框内黑色 7 段大数字（数字高 220、宽 140、笔画 26，居中于白框）
    Add-Digit -Buf $buf -Stride $stride -ImgW $W -ImgH $H `
              -Digit $Index -X0 250 -Y0 130 -DW 140 -DH 220 -T 26 `
              -Cr 0 -Cg 0 -Cb 0

    # ⑤ 右下角 Index 个白色小方块（每块 24x24，间距 8，贴右边缘内侧）
    for ($i = 0; $i -lt $Index; $i++) {
        $bx = 600 - 40 - ($i * 32)
        Add-Rect -Buf $buf -Stride $stride -ImgW $W -ImgH $H `
                 -X0 $bx -Y0 400 -RW 24 -RH 24 -Cr 255 -Cg 255 -Cb 255
    }

    $sz = Save-Bmp24 -Path $Path -ImgW $W -ImgH $H -Pixels $buf -Stride $stride
    return $sz
}

# -----------------------------------------------------------------------------
# 工具 6: 生成"尺寸不符"坏图（320x240）—— 用于验证 bmp_parser 的宽高检查
# -----------------------------------------------------------------------------
function New-BadSizeImage {
    param([string]$Path)
    $W = 320; $H = 240
    $stride = Get-Stride24 -ImgW $W
    $buf = New-Object byte[] ($stride * $H)
    # 黑底 + 中央红块，随便画，反正这张图一定会被拒绝
    Add-Rect -Buf $buf -Stride $stride -ImgW $W -ImgH $H -X0 0 -Y0 0 -RW $W -RH $H -Cr 0 -Cg 0 -Cb 0
    Add-Rect -Buf $buf -Stride $stride -ImgW $W -ImgH $H -X0 60 -Y0 40 -RW 200 -RH 160 -Cr 255 -Cg 0 -Cb 0
    $sz = Save-Bmp24 -Path $Path -ImgW $W -ImgH $H -Pixels $buf -Stride $stride
    return $sz
}

# =============================================================================
# 主流程
# =============================================================================
Write-Host ''
Write-Host '=== 生成上板验证 SD 素材 ===' -ForegroundColor Cyan
Write-Host "输出根目录: $OutRoot"

$dirs = @{
    good     = Join-Path $OutRoot 'good'
    bad_size = Join-Path $OutRoot 'bad_size'
    bad_bmp  = Join-Path $OutRoot 'bad_bmp'
    empty    = Join-Path $OutRoot 'empty'
}
foreach ($d in $dirs.Values) {
    if (Test-Path $d) { Remove-Item $d -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# ---- 6 张正常素材：每张一个专属背景色 ----
# 颜色选择原则: 相邻序号色相差要大，这样"按一下换了没有"不用数数字也能判断。
$palette = @(
    @{ R = 24;  G = 24;  B = 48  },   # 1 深蓝
    @{ R = 24;  G = 72;  B = 32  },   # 2 深绿
    @{ R = 96;  G = 24;  B = 24  },   # 3 深红
    @{ R = 96;  G = 72;  B = 16  },   # 4 深黄
    @{ R = 24;  G = 72;  B = 88  },   # 5 深青
    @{ R = 80;  G = 24;  B = 80  }    # 6 深紫
)

Write-Host ''
Write-Host '[1/4] 生成 good\ (IMG001~IMG006.BMP)' -ForegroundColor Yellow
for ($i = 1; $i -le 6; $i++) {
    $c = $palette[$i - 1]
    $p = Join-Path $dirs.good ('IMG{0:D3}.BMP' -f $i)
    $sz = New-IndexImage -Path $p -Index $i -BgR $c.R -BgG $c.G -BgB $c.B
    Write-Host ("      IMG{0:D3}.BMP  {1,9:N0} B  背景 RGB({2},{3},{4})" -f $i, $sz, $c.R, $c.G, $c.B)
}

Write-Host ''
Write-Host '[2/4] 生成 bad_size\ (IMG001 正常 + IMG002 为 320x240)' -ForegroundColor Yellow
Copy-Item (Join-Path $dirs.good 'IMG001.BMP') (Join-Path $dirs.bad_size 'IMG001.BMP')
$sz = New-BadSizeImage -Path (Join-Path $dirs.bad_size 'IMG002.BMP')
Write-Host ("      IMG002.BMP  {0,9:N0} B  320x240 → 期望 bmp_parser err=4（宽高不符）" -f $sz)

Write-Host ''
Write-Host '[3/4] 生成 bad_bmp\ (IMG001 正常 + IMG002 签名被破坏)' -ForegroundColor Yellow
Copy-Item (Join-Path $dirs.good 'IMG001.BMP') (Join-Path $dirs.bad_bmp 'IMG001.BMP')
$src = [System.IO.File]::ReadAllBytes((Join-Path $dirs.good 'IMG002.BMP'))
$src[0] = 0x58   # 'X'
$src[1] = 0x58   # 'X'  → 不再是 "BM" 签名
[System.IO.File]::WriteAllBytes((Join-Path $dirs.bad_bmp 'IMG002.BMP'), $src)
Write-Host ("      IMG002.BMP  {0,9:N0} B  签名 'XX' → 期望 bmp_parser err=1（非 BM）" -f $src.Length)

Write-Host ''
Write-Host '[4/4] 生成 empty\ (无任何 IMGnnn.BMP)' -ForegroundColor Yellow
$notePath = Join-Path $dirs.empty 'README.txt'
$note = @'
此目录刻意不含任何 IMGnnn.BMP 文件。

用途：验证"卡是好的、但一张图都没有"这条提示路径。
      期望数码管最左两位显示 0 0（助记字母 CH_NONE + 子码 0），
      LED[7]（最左那颗，err_active）点亮，蜂鸣器 1.5 秒后响 3 秒。

把本目录下的文件（只有这个 README.txt）整体拷到 SD 卡根目录即可。
'@
[System.IO.File]::WriteAllText($notePath, $note, (New-Object System.Text.UTF8Encoding($false)))
Write-Host '      README.txt（说明文件，无图片）'

# ---- 汇总 ----
Write-Host ''
Write-Host '=== 完成 ===' -ForegroundColor Cyan
$total = 0
foreach ($k in @('good', 'bad_size', 'bad_bmp', 'empty')) {
    $d = $dirs[$k]
    $files = Get-ChildItem $d -File
    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    if (-not $bytes) { $bytes = 0 }
    $total += $bytes
    Write-Host ("  {0,-9}  {1,2} 个文件  {2,10:N0} B" -f $k, $files.Count, $bytes)
}
Write-Host ("  合计      {0,10:N0} B  ({1:N1} MB)" -f $total, ($total / 1MB))
Write-Host ''
Write-Host '下一步：按 docs/board_verification_2026-10-27.md 的阶段顺序使用这些目录。'
Write-Host '  阶段 D~H 用 good\，阶段 I 依次换成 bad_size\、bad_bmp\、empty\。'
Write-Host ''
