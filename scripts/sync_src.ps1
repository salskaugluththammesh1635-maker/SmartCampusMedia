# =============================================================================
# sync_src.ps1 — 主源 → TD 工程副本 同步（双工程：bringup_td 最小系统 + hdmi_td 视频）
# -----------------------------------------------------------------------------
# 背景: 代码唯一真源在 rtl/ 与 constraints/，而 TD 编译的是 project/ 下的副本。
#       手工复制易漏（已发生过：key_matrix_4x4.v 两边不一致），故标准化此动作。
# 用法:
#   powershell -ExecutionPolicy Bypass -File scripts\sync_src.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\sync_src.ps1 -NoLint
# =============================================================================
param(
    [switch]$NoLint
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$base = Split-Path -Parent $PSScriptRoot
Set-Location $base

# ---- 主源 -> 目标列表（一个源可同步到多个 TD 工程；哈希表键必须唯一）----
$map = [ordered]@{
    # ===== 两工程共用（同一源同步到两份副本）=====
    'rtl\common\seg_decoder.v'      = @('project\src\seg_decoder.v',      'project\hdmi\seg_decoder.v')
    'rtl\display\seg_scan4.v'       = @('project\src\seg_scan4.v',        'project\hdmi\seg_scan4.v')
    'rtl\input\key_matrix_4x4.v'    = @('project\src\key_matrix_4x4.v',   'project\hdmi\key_matrix_4x4.v')
    'rtl\audio\buzzer_tone.v'       = @('project\src\buzzer_tone.v',      'project\hdmi\buzzer_tone.v')
    'rtl\audio\pwm_audio_out.v'     = @('project\hdmi\pwm_audio_out.v')
    # ===== 仅 hdmi_td（阶段四存储链）=====
    'rtl\storage\sd_spi_ctrl.v'     = @('project\hdmi\sd_spi_ctrl.v')
    'rtl\storage\sd_probe.v'        = @('project\hdmi\sd_probe.v')
    'rtl\storage\fat32_reader.v'    = @('project\hdmi\fat32_reader.v')
    # ===== 仅 hdmi_td =====
    'rtl\top\dmz_eg4s20_hdmi_top.v' = @('project\hdmi\dmz_eg4s20_hdmi_top.v')
    'rtl\video\hdmi\hdmi_pll.v'     = @('project\hdmi\hdmi_pll.v')
    'rtl\video\hdmi\hdmi_tx.vhd'    = @('project\hdmi\hdmi_tx.vhd')
    'rtl\video\video_timing_gen.v'  = @('project\hdmi\video_timing_gen.v')
    'rtl\video\test_pattern_gen.v'  = @('project\hdmi\test_pattern_gen.v')
    # ===== 仅 bringup_td =====
    'rtl\top\dmz_eg4s20_min_top.v'  = @('project\src\dmz_eg4s20_min_top.v')
    # ===== 约束文件 =====
    'constraints\dmz_eg4s20_min.adc'  = @('project\src\dmz_eg4s20_min.adc')
    'constraints\dmz_eg4s20_hdmi.adc' = @('project\hdmi\dmz_eg4s20_hdmi.adc')
    # ===== 时序约束（SDC，2026-10-17 第五轮审查新增）=====
    'constraints\dmz_eg4s20_hdmi.sdc' = @('project\hdmi\dmz_eg4s20_hdmi.sdc')
    # ===== 官方加密 IP（仅复制，不参与 lint）=====
    'ip\local\hdmi\enc\DVITransmitter.enc.vhd'         = @('project\hdmi\enc\DVITransmitter.enc.vhd')
    'ip\local\hdmi\enc\SerializerN_1_lvds.enc.vhd'     = @('project\hdmi\enc\SerializerN_1_lvds.enc.vhd')
    'ip\local\hdmi\enc\SerializerN_1_lvds_dat.enc.vhd' = @('project\hdmi\enc\SerializerN_1_lvds_dat.enc.vhd')
    'ip\local\hdmi\enc\TMDSEncoder.enc.vhd'            = @('project\hdmi\enc\TMDSEncoder.enc.vhd')
}

Write-Host "=== 同步 主源 -> TD 工程副本 ===" -ForegroundColor Cyan
$changed = 0
$total = 0
foreach ($src in $map.Keys) {
    foreach ($dst in $map[$src]) {
        $total++
        if (-not (Test-Path $src)) {
            Write-Host ("  [跳过] 主源不存在: {0}" -f $src) -ForegroundColor Yellow
            continue
        }
        $needCopy = $true
        if (Test-Path $dst) {
            if ((Get-FileHash $src -Algorithm MD5).Hash -eq (Get-FileHash $dst -Algorithm MD5).Hash) {
                $needCopy = $false
            }
        }
        if ($needCopy) {
            $dir = Split-Path -Parent $dst
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            Copy-Item $src $dst -Force
            Write-Host ("  [已更新] {0}" -f $dst) -ForegroundColor Green
            $changed++
        }
        else {
            Write-Host ("  [未变化] {0}" -f $dst) -ForegroundColor DarkGray
        }
    }
}
Write-Host ("同步完成: {0}/{1} 个副本被更新" -f $changed, $total) -ForegroundColor Cyan

if (-not $NoLint) {
    Write-Host "`n=== 同步后静态检查（rtl + 两个工程副本）===" -ForegroundColor Cyan
    python scripts\lint_verilog.py rtl project\src project\hdmi
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n[警告] lint 未通过, 请修复后再用 TD 编译" -ForegroundColor Red
        exit 1
    }
    Write-Host "`n[OK] lint 通过。TD 中重新编译: 选中 Read Design 按 Shift+R" -ForegroundColor Green
}
