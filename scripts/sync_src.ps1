# =============================================================================
# sync_src.ps1 — 把 rtl/ 主源同步到 project/src/（安路 TD 工程编译副本）
# -----------------------------------------------------------------------------
# 背景: project/src/ 是 TD 工程（bringup_td.al）实际编译的目录, 而代码唯一
#       真源在 rtl/。手工复制容易漏文件, 导致"仿真过了但板子上是旧代码"。
#       本脚本把同步动作标准化, 并在同步后自动跑 lint 双查。
# 用法:
#   powershell -ExecutionPolicy Bypass -File scripts\sync_src.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\sync_src.ps1 -NoLint   # 跳过检查
# =============================================================================
param(
    [switch]$NoLint
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$base = Split-Path -Parent $PSScriptRoot      # 仓库根 = scripts 的上级
Set-Location $base

# ---- 主源 -> TD 工程副本 的映射表（新增文件时在此登记）----
$map = [ordered]@{
    'rtl\audio\buzzer_tone.v'          = 'project\src\buzzer_tone.v'
    'rtl\display\seg_scan4.v'          = 'project\src\seg_scan4.v'
    'rtl\common\seg_decoder.v'         = 'project\src\seg_decoder.v'
    'rtl\input\key_matrix_4x4.v'       = 'project\src\key_matrix_4x4.v'
    'rtl\top\dmz_eg4s20_min_top.v'     = 'project\src\dmz_eg4s20_min_top.v'
    'constraints\dmz_eg4s20_min.adc'   = 'project\src\dmz_eg4s20_min.adc'
}

Write-Host "=== 同步 rtl/ -> project/src/ ===" -ForegroundColor Cyan
$changed = 0
foreach ($src in $map.Keys) {
    $dst = $map[$src]
    if (-not (Test-Path $src)) {
        Write-Host ("  [跳过] 主源不存在: {0}" -f $src) -ForegroundColor Yellow
        continue
    }
    $needCopy = $true
    if (Test-Path $dst) {
        $h1 = (Get-FileHash $src -Algorithm MD5).Hash
        $h2 = (Get-FileHash $dst -Algorithm MD5).Hash
        if ($h1 -eq $h2) { $needCopy = $false }
    }
    if ($needCopy) {
        Copy-Item $src $dst -Force
        Write-Host ("  [已更新] {0}" -f $dst) -ForegroundColor Green
        $changed++
    }
    else {
        Write-Host ("  [未变化] {0}" -f $dst) -ForegroundColor DarkGray
    }
}
Write-Host ("同步完成: {0} 个文件被更新" -f $changed) -ForegroundColor Cyan

if (-not $NoLint) {
    Write-Host "`n=== 同步后静态检查（rtl + src 双查）===" -ForegroundColor Cyan
    python scripts\lint_verilog.py rtl project\src
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n[警告] lint 未通过, 请修复后再用 TD 编译" -ForegroundColor Red
        exit 1
    }
    Write-Host "`n[OK] lint 通过, 可在 TD 中重新编译（选中 Read Design 按 Shift+R）" -ForegroundColor Green
}
