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
    # Project-owned SDRAM config; local is a compatibility copy for vendor tools.
    'ip\config\sdram\global_def.v' = @('ip\local\sdram\global_def.v')
    # ===== 两工程共用（同一源同步到两份副本）=====
    'rtl\common\seg_decoder.v'                         = @('project\src\seg_decoder.v',      'project\hdmi\seg_decoder.v')
    'rtl\display\seg_scan4.v'                          = @('project\src\seg_scan4.v',        'project\hdmi\seg_scan4.v')
    'rtl\input\key_matrix_4x4.v'                       = @('project\src\key_matrix_4x4.v',   'project\hdmi\key_matrix_4x4.v')
    'rtl\audio\buzzer_tone.v'                          = @('project\src\buzzer_tone.v',      'project\hdmi\buzzer_tone.v')
    'rtl\audio\pwm_audio_out.v'                        = @('project\hdmi\pwm_audio_out.v')
    # ===== 仅 hdmi_td：HDMI 音频嵌入链路（S8）=====
    # audio_tone_gen 是音频源（48 kHz PCM），pcm_to_pwm 把同一份 PCM 调制到模拟
    # 引脚；audio_arc 产生 ACR 的 CTS/N；video_rgb_to_axis 把 DVI 风格视频翻译成
    # 带音频核要的 AXIS 流；hdmi_phy + lane_lvds_10_1 做 TMDS 串化。
    'rtl\audio\audio_tone_gen.v'                       = @('project\hdmi\audio_tone_gen.v')
    'rtl\audio\pcm_to_pwm.v'                           = @('project\hdmi\pcm_to_pwm.v')
    'rtl\video\hdmi\audio_arc.v'                       = @('project\hdmi\audio_arc.v')
    'rtl\video\hdmi\video_rgb_to_axis.v'               = @('project\hdmi\video_rgb_to_axis.v')
    'rtl\video\hdmi\hdmi_phy.v'                        = @('project\hdmi\hdmi_phy.v')
    'rtl\video\hdmi\lane_lvds_10_1.v'                  = @('project\hdmi\lane_lvds_10_1.v')
    # ===== 仅 hdmi_td（阶段四存储链）=====
    'rtl\storage\sd_spi_ctrl.v'                        = @('project\hdmi\sd_spi_ctrl.v')
    'rtl\storage\sd_probe.v'                           = @('project\hdmi\sd_probe.v')
    'rtl\storage\fat32_reader.v'                       = @('project\hdmi\fat32_reader.v')
    'rtl\storage\gallery_probe.v'                      = @('project\hdmi\gallery_probe.v')
    'rtl\storage\bmp_parser.v'                         = @('project\hdmi\bmp_parser.v')
    'rtl\common\async_fifo.v'                          = @('project\hdmi\async_fifo.v')
    'rtl\storage\framebuf_arbiter.v'                   = @('project\hdmi\framebuf_arbiter.v')
    'rtl\storage\sdram_pll.v'                          = @('project\hdmi\sdram_pll.v')
    'rtl\storage\sdram_ctrl_wrap.v'                    = @('project\hdmi\sdram_ctrl_wrap.v')
    'rtl\storage\sdram_bringup_top.v'                  = @('project\hdmi\sdram_bringup_top.v')
    'rtl\storage\img_loader.v'                         = @('project\hdmi\img_loader.v')
    'rtl\storage\image_player.v'                       = @('project\hdmi\image_player.v')
    'rtl\storage\pix_reader.v'                         = @('project\hdmi\pix_reader.v')
    # B2 换帧转场：淡出到黑再淡入的纯组合像素缩放器（image_player 内例化）
    'rtl\storage\fade_mixer.v'                         = @('project\hdmi\fade_mixer.v')
    # C2 自适应缩放：bmp_parser -> img_scaler -> img_loader，保持宽高比居中抽稀
    'rtl\storage\img_scaler.v'                         = @('project\hdmi\img_scaler.v')
    'rtl\control\player_ctrl.v'                        = @('project\hdmi\player_ctrl.v')
    'rtl\control\err_prompt.v'                         = @('project\hdmi\err_prompt.v')
    # ===== 仅 hdmi_td：扩展键译码与像素后处理（KEY7~KEY14）=====
    # key_action 是 KEY7~KEY14 的唯一译码点（顶层不再单独消费这 8 个键号）；
    # video_overlay 做亮度/反色/九宫格/信息条/电平条/波形，
    # 波形历史在 audio_waveform 子模块内寄存，像素输出仍同拍。
    'rtl\control\key_action.v'                         = @('project\hdmi\key_action.v')
    'rtl\video\audio_waveform.v'                       = @('project\hdmi\audio_waveform.v')
    'rtl\video\video_overlay.v'                        = @('project\hdmi\video_overlay.v')
    'rtl\video\science_font16.v'                       = @('project\hdmi\science_font16.v')
    'rtl\video\science_page.v'                         = @('project\hdmi\science_page.v')
    'rtl\video\video_content_mux.v'                    = @('project\hdmi\video_content_mux.v')
    # letterbox 窗口屏蔽：把缩放窗口外的帧缓存旧内容强制成黑
    'rtl\video\image_window_mask.v'                    = @('project\hdmi\image_window_mask.v')
    # ===== 仅 hdmi_td：B3 实时参数 OSD 面板（rtl/osd/ 首次落地）=====
    # osd_param_text 决定"显示哪些字"（纯组合字符码表），
    # osd_font8x16 是 8x16 ASCII 字模 ROM（由 scripts/gen_osd_font8.py 生成，
    #   不要手改；改字库请改生成器再 --emit），
    # osd_panel 把字符码+字模摆到画面右上角并做暗色玻璃底，
    # osd_autopop 在参数变化后自动弹窗 2.5 秒（不占键号）。
    'rtl\osd\osd_param_text.v'                         = @('project\hdmi\osd_param_text.v')
    'rtl\osd\osd_font8x16.v'                           = @('project\hdmi\osd_font8x16.v')
    'rtl\osd\osd_panel.v'                              = @('project\hdmi\osd_panel.v')
    'rtl\osd\osd_autopop.v'                            = @('project\hdmi\osd_autopop.v')
    # ===== 仅 hdmi_td：B1 图层叠加与字幕 =====
    # osd_strings 是"哪一行第几列显示什么字"（由 scripts/gen_osd_strings.py 生成，
    #   不要手改；改文案请改生成器里的 LINE_* 常量再 --emit），
    # osd_caption 把字符码摆到标题/序号/状态/标语四处并算滚动偏移。
    'rtl\osd\osd_strings.v'                            = @('project\hdmi\osd_strings.v')
    'rtl\osd\osd_caption.v'                            = @('project\hdmi\osd_caption.v')
    # ===== 仅 hdmi_td =====
    'rtl\top\dmz_eg4s20_hdmi_top.v'                    = @('project\hdmi\dmz_eg4s20_hdmi_top.v')
    'rtl\video\hdmi\hdmi_pll.v'                        = @('project\hdmi\hdmi_pll.v')
    # hdmi_tx.vhd（DVI 核端口映射）自 S8 起不再被顶层引用：带音频通路必须走
    # hdmi_1_4b_transmitter_core。文件保留在 rtl/ 里作为历史参照与回退路径，
    # 但不再同步、不再进 TD 工程（否则会与 hdmi_1_4b 核争同一组 TMDS 引脚定义）。
    'rtl\video\video_timing_gen.v'                     = @('project\hdmi\video_timing_gen.v')
    'rtl\video\test_pattern_gen.v'                     = @('project\hdmi\test_pattern_gen.v')
    # ===== 仅 bringup_td =====
    'rtl\top\dmz_eg4s20_min_top.v'                     = @('project\src\dmz_eg4s20_min_top.v')
    # ===== 约束文件 =====
    'constraints\dmz_eg4s20_min.adc'                   = @('project\src\dmz_eg4s20_min.adc')
    'constraints\dmz_eg4s20_hdmi.adc'                  = @('project\hdmi\dmz_eg4s20_hdmi.adc')
    # ===== 时序约束（SDC，2026-10-17 第五轮审查新增）=====
    'constraints\dmz_eg4s20_hdmi.sdc'                  = @('project\hdmi\dmz_eg4s20_hdmi.sdc')
    # ===== 官方加密 IP（仅复制，不参与 lint）=====
    # DVI 核的四个 VHDL 加密件（DVITransmitter / TMDSEncoder / SerializerN_1_*）
    # 随 hdmi_tx.vhd 一起退出构建：S8 换成 HDMI 1.4b 核后不再需要它们。
    'ip\local\hdmi\enc\hdmi_1_4b_transmitter_core_wrapper.enc.v' = @('project\hdmi\enc\hdmi_1_4b_transmitter_core_wrapper.enc.v')
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
