# =============================================================================
# run_unit_coverage_regression.ps1
# -----------------------------------------------------------------------------
# Unit-coverage regression: runs 18 module-level testbenches that cover RTL
# modules which previously had no testbench at all.
#
# Covered modules (each testbench targets one untested RTL module):
#   tb_lane_lvds_10_1      rtl/video/hdmi/lane_lvds_10_1.v     10bit serializer
#   tb_hdmi_phy            rtl/video/hdmi/hdmi_phy.v            4-lane TMDS PHY
#   tb_video_timing_gen    rtl/video/video_timing_gen.v         640x480 timing gen
#   tb_test_pattern_gen    rtl/video/test_pattern_gen.v         8 test patterns
#   tb_video_rgb_to_axis   rtl/video/hdmi/video_rgb_to_axis.v   RGB -> AXI4-Stream
#   tb_audio_arc           rtl/video/hdmi/audio_arc.v           HDMI ACR packets
#   tb_audio_tone_gen      rtl/audio/audio_tone_gen.v           triangle tone gen
#   tb_audio_waveform      rtl/video/audio_waveform.v           audio scope layer
#   tb_pcm_to_pwm          rtl/audio/pcm_to_pwm.v               sigma-delta DAC
#   tb_key_matrix_4x4      rtl/input/key_matrix_4x4.v           4x4 key scan
#   tb_ax_debounce         rtl/common/ax_debounce.v             button debouncer
#   tb_seg_decoder         rtl/common/seg_decoder.v             7-segment decoder
#   tb_image_path_probe    rtl/storage/image_path_probe.v       image path probe
#   tb_hdmi_pll            rtl/video/hdmi/hdmi_pll.v           25MHz + exact 5x 125MHz
#   tb_sdram_pll           rtl/storage/sdram_pll.v             40MHz 0deg + 180deg pair
#   tb_dmz_eg4s20_min_top  rtl/top/dmz_eg4s20_min_top.v        whole-system integration
#   tb_science_font16      rtl/video/science_font16.v          16x16 glyph ROM
#   tb_sdram_frame_diag_top rtl/storage/sdram_frame_diag.v     SDRAM frame BIST top
#
# WHY THIS SCRIPT NEEDS THE ANLOGIC PRIMITIVE LIBRARY
#   lane_lvds_10_1 / hdmi_phy instantiate the EG_LOGIC_ODDR primitive. The
#   vendor model eg_logic_io.v contains `tri1 gsr_n = glbl.gsrn;`, so
#   eg_phy_glbl.v (which defines module glbl) must be compiled too. Without it
#   gsr_n stays x and poisons the whole chain. At run time glbl must ALSO be
#   passed as a second top-level:
#       vsim ... work.tb_xxx glbl
#   Otherwise gsrn never rises and the DUT sits in reset forever.
#
#   tb_sdram_frame_diag_top additionally needs eg_phy_sdram_2m_32.v: the
#   sdram_frame_diag_top module instantiates EG_PHY_SDRAM_2M_32 OUTSIDE the
#   `ifdef SDRAM_SIM_MODEL guard, so the vendor SDRAM model has to be present
#   even though the controller itself switches to the inline behavioural model.
#   SDRAM_SIM_MODEL is defined for the whole compile, which is harmless for the
#   other testbenches.
#
# WHY THE COMMENTS HERE ARE ASCII ONLY
#   This file is stored as UTF-8 WITHOUT a BOM (same as most scripts in this
#   repo). Windows PowerShell 5.1 reads such files using the ANSI/GBK code page,
#   and a multi-byte Chinese comment can then swallow a following quote/brace,
#   producing bogus "Unexpected token" parse errors. Keeping the script itself
#   ASCII-only makes it runnable from both powershell.exe 5.1 and pwsh.
#   Chinese explanations live in the .v testbenches and README instead.
#
# KNOWN ISSUES (currently none)
#   Three real RTL defects were found by these testbenches and have since been
#   FIXED in RTL, so the corresponding checks are now hard assertions:
#     - pcm_to_pwm.v      : sigma-delta feedback took bit31 of the truncated sum
#                           instead of the carry (audio was permanently silent).
#                           Fixed: 33-bit accumulator, pwm_q <= acc_next[32].
#     - test_pattern_gen.v: moving-box turn-around used `box_x == 0` on the
#                           pre-update value, so the return leg underflowed
#                           (11-bit 0-64 = 1984) and the box flew off screen.
#                           Fixed: `box_x <= BOX_SIZE` / `box_y <= BOX_SIZE`.
#     - dmz_eg4s20_min_top.v: `.tone_sel(2'd1)` into a 3-bit port. ModelSim
#                           zero-extends with z (not 0) at a port connection,
#                           so tone_sel became 3'bz01 and the buzzer was mute.
#                           Fixed: `.tone_sel(3'd1)`.
#   The testbenches keep both the symptom assertion and the root-cause nail, so
#   a regression of any of these defects fails immediately. This script still
#   records known_issues into result.json in case a new defect is registered.
# =============================================================================
[CmdletBinding()]
param(
    [string]$ModelSimPath = 'D:\Quartus_APP\modelsim_ase\win32aloem',
    [string]$PrimLibPath  = 'D:\TD_6_24_APP\sim_release\eg4',
    # Default report directory lives under the OS temp area on purpose: this
    # environment denies creating sub-directories inside the repository, so a
    # repo-relative default would fail at the first New-Item. Pass -ReportDir
    # explicitly if you run this on a machine where that is allowed.
    [string]$ReportDir    = (Join-Path $env:TEMP 'scm_unit_coverage')
)

$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not [IO.Path]::IsPathRooted($ReportDir)) { $ReportDir = Join-Path $root $ReportDir }
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

# ---- ModelSim tools present? -----------------------------------------------
foreach ($tool in @('vlib', 'vlog', 'vsim')) {
    $exe = Join-Path $ModelSimPath ($tool + '.exe')
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "Missing ModelSim tool: $tool.exe under $ModelSimPath"
    }
}

# ---- Vendor primitive models present? --------------------------------------
# eg_phy_pll.v and eg_logic_clk.v are only needed by the two PLL testbenches:
# EG_PHY_PLL is a real divider model (it measures the reference clock and then
# drives the VCO at the computed period), and EG_LOGIC_BUFG lives in
# eg_logic_clk.v. Both are checked here so a missing library fails loudly
# instead of producing an "Instantiation of 'EG_LOGIC_BUFG' failed" load error.
foreach ($f in @('eg_logic_io.v', 'eg_phy_glbl.v', 'eg_phy_pll.v', 'eg_logic_clk.v',
                 'eg_phy_sdram_2m_32.v')) {
    $p = Join-Path $PrimLibPath $f
    if (-not (Test-Path -LiteralPath $p)) {
        throw ("Missing Anlogic primitive model: $f under $PrimLibPath. " +
               "Pass -PrimLibPath <TD install>\sim_release\eg4")
    }
}

# ---- Compile list ----------------------------------------------------------
# Absolute entries (vendor library) are used verbatim; relative entries are
# resolved against the repository root.
$sources = @(
    (Join-Path $PrimLibPath 'eg_logic_io.v'),
    (Join-Path $PrimLibPath 'eg_phy_glbl.v'),
    (Join-Path $PrimLibPath 'eg_phy_pll.v'),
    (Join-Path $PrimLibPath 'eg_logic_clk.v'),
    (Join-Path $PrimLibPath 'eg_phy_sdram_2m_32.v'),

    'rtl/video/hdmi/lane_lvds_10_1.v',
    'rtl/video/hdmi/hdmi_phy.v',
    'rtl/video/hdmi/video_rgb_to_axis.v',
    'rtl/video/hdmi/audio_arc.v',
    'rtl/video/hdmi/hdmi_pll.v',
    'rtl/video/video_timing_gen.v',
    'rtl/video/test_pattern_gen.v',
    'rtl/video/audio_waveform.v',
    'rtl/video/science_font16.v',

    'rtl/audio/audio_tone_gen.v',
    'rtl/audio/pcm_to_pwm.v',

    'rtl/input/key_matrix_4x4.v',
    'rtl/common/ax_debounce.v',
    'rtl/common/seg_decoder.v',
    'rtl/audio/buzzer_tone.v',
    'rtl/display/seg_scan4.v',

    'rtl/storage/image_path_probe.v',
    'rtl/storage/sdram_pll.v',
    'rtl/storage/sdram_ctrl_wrap.v',
    'rtl/storage/sdram_frame_diag.v',

    # --- v2 control layer ---------------------------------------------------
    'rtl/video/brightness_apply.v',
    'rtl/control/mode_ctrl.v',
    'rtl/control/key_router.v',

    # --- v2 sensor layer ----------------------------------------------------
    'rtl/sensor/i2c_master.v',
    'rtl/sensor/aht20_ctrl.v',
    'rtl/sensor/thermal_guard.v',

    'rtl/top/dmz_eg4s20_min_top.v',

    'sim/testbench/tb_lane_lvds_10_1.v',
    'sim/testbench/tb_hdmi_phy.v',
    'sim/testbench/tb_video_rgb_to_axis.v',
    'sim/testbench/tb_audio_arc.v',
    'sim/testbench/tb_hdmi_pll.v',
    'sim/testbench/tb_video_timing_gen.v',
    'sim/testbench/tb_test_pattern_gen.v',
    'sim/testbench/tb_audio_waveform.v',
    'sim/testbench/tb_audio_tone_gen.v',
    'sim/testbench/tb_pcm_to_pwm.v',
    'sim/testbench/tb_key_matrix_4x4.v',
    'sim/testbench/tb_ax_debounce.v',
    'sim/testbench/tb_seg_decoder.v',
    'sim/testbench/tb_image_path_probe.v',
    'sim/testbench/tb_sdram_pll.v',
    'sim/testbench/tb_dmz_eg4s20_min_top.v',
    'sim/testbench/tb_science_font16.v',
    'sim/testbench/tb_sdram_frame_diag_top.v',

    # --- v2 testbenches -----------------------------------------------------
    'sim/testbench/tb_brightness_apply.v',
    'sim/testbench/tb_mode_ctrl.v',
    'sim/testbench/tb_key_router.v',
    'sim/testbench/tb_i2c_master.v',
    'sim/testbench/tb_aht20_ctrl.v',
    'sim/testbench/tb_thermal_guard.v',

    # --- v2 t6 audio path (SD WAV streaming + volume + source mux) ----------
    'rtl/audio/vol_apply.v',
    'rtl/audio/audio_src_mux.v',
    'rtl/audio/wav_stream_player.v',
    'rtl/storage/fat32_reader.v',
    'sim/testbench/tb_fat32_reader.v',
    'sim/testbench/tb_gain_direction.v',
    'sim/testbench/tb_vol_apply.v',
    'sim/testbench/tb_audio_src_mux.v',
    'sim/testbench/tb_wav_stream_player.v'
)

$resolved = @($sources | ForEach-Object {
    if ([IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $root $_ }
})

# Fail fast on a missing file instead of letting vlog emit unrelated errors.
foreach ($f in $resolved) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Missing source file: $f" }
}

# ---- Fingerprint every source so a mid-run edit is detected ----------------
$hashes = @($resolved | ForEach-Object {
    @{ path = $_; sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
})

$result = [ordered]@{
    suite        = 'unit_coverage'
    startedAt    = (Get-Date).ToString('o')
    status       = 'running'
    modelSimPath = $ModelSimPath
    primLibPath  = $PrimLibPath
    sources      = $hashes
    tests        = @()
}
$failed = $false

# ---- A4 分母断言（t9 加）---------------------------------------------------
# 只断言「没有失败」在「一个 case 都没跑」时同样成立，而「一个 case 都没跑」
# 恰恰是最该报警的状态。所以收尾必须同时断言分母三件事：
#   $script:A4Ran -gt 0                —— 真的跑了
#   $script:A4Ran -eq $ExpCaseCount    —— 跑的个数等于这张表该有的个数
#   $script:A4Passed -eq $script:A4Ran   —— 每一个都过了
# 必须用 $script: 前缀：将来若把主流程包进函数，函数里的 += 改的是局部副本，
# 外层判据会永远看到 0 → 打印 PASS（scripts\run_tb_baseline.ps1 头注记着这个坑）。
# 也刻意不写 $ExpCaseCount = @($cases).Count —— 那是同源自证：case 表被误删时
# 期望值会跟着一起变小，断言永远成立。
$script:A4Ran    = 0
$script:A4Passed = 0
$ExpCaseCount  = 29   # unit 套件应有 case 数（默认档）；tb 增删必须同步改这里

Push-Location $ReportDir
try {
    # ---- Build the library ------------------------------------------------
    if (-not (Test-Path 'work')) {
        & (Join-Path $ModelSimPath 'vlib.exe') work *> vlib.log
        if ($LASTEXITCODE -ne 0) { throw 'vlib failed; inspect vlib.log' }
    }

    # ---- Compile ----------------------------------------------------------
    # +define+SDRAM_SIM_MODEL makes sdram_ctrl_wrap instantiate its inline
    # behavioural SDRAM model instead of talking to the (encrypted) vendor
    # device model. Harmless for every other testbench in this list.
    & (Join-Path $ModelSimPath 'vlog.exe') -quiet +define+SDRAM_SIM_MODEL @resolved *> compile.log
    if ($LASTEXITCODE -ne 0) {
        throw 'vlog failed; no stale simulation was run; inspect compile.log'
    }

    # ---- Case table -------------------------------------------------------
    # glbl=$true appends glbl as a second top-level so the vendor global reset
    # releases about 20ns after time zero.
    $cases = @(
        @{name='lane_lvds_10_1';    top='tb_lane_lvds_10_1';    glbl=$true;
          marker='ALL CHECKS PASSED: lane_lvds_10_1'},
        @{name='hdmi_phy';          top='tb_hdmi_phy';          glbl=$true;
          marker='ALL CHECKS PASSED: hdmi_phy'},
        @{name='video_rgb_to_axis'; top='tb_video_rgb_to_axis'; glbl=$false;
          marker='ALL CHECKS PASSED: video_rgb_to_axis'},
        @{name='audio_arc';         top='tb_audio_arc';         glbl=$false;
          marker='ALL CHECKS PASSED: audio_arc'},
        @{name='video_timing_gen';  top='tb_video_timing_gen';  glbl=$false;
          marker='ALL CHECKS PASSED: video_timing_gen'},
        @{name='test_pattern_gen';  top='tb_test_pattern_gen';  glbl=$false;
          marker='ALL CHECKS PASSED: test_pattern_gen'},
        @{name='audio_waveform';    top='tb_audio_waveform';    glbl=$false;
          marker='ALL CHECKS PASSED: audio_waveform'},
        @{name='audio_tone_gen';    top='tb_audio_tone_gen';    glbl=$false;
          marker='ALL CHECKS PASSED: audio_tone_gen'},
        @{name='pcm_to_pwm';        top='tb_pcm_to_pwm';        glbl=$false;
          marker='ALL CHECKS PASSED: pcm_to_pwm'},
        @{name='key_matrix_4x4';    top='tb_key_matrix_4x4';    glbl=$false;
          marker='ALL CHECKS PASSED: key_matrix_4x4'},
        @{name='ax_debounce';       top='tb_ax_debounce';       glbl=$false;
          marker='ALL CHECKS PASSED: ax_debounce'},
        @{name='seg_decoder';       top='tb_seg_decoder';       glbl=$false;
          marker='ALL CHECKS PASSED: seg_decoder'},
        @{name='image_path_probe';  top='tb_image_path_probe';  glbl=$false;
          marker='ALL CHECKS PASSED: image_path_probe'},
        @{name='hdmi_pll';          top='tb_hdmi_pll';          glbl=$true;
          marker='ALL CHECKS PASSED: hdmi_pll'},
        @{name='sdram_pll';         top='tb_sdram_pll';         glbl=$true;
          marker='ALL CHECKS PASSED: sdram_pll'},
        # Whole-system integration: dmz_eg4s20_min_top is the only top-level that
        # has neither encrypted IP nor a PLL, so it is the only one that can be
        # simulated end-to-end. Takes about 60s (real 50MHz time scale).
        @{name='dmz_eg4s20_min_top'; top='tb_dmz_eg4s20_min_top'; glbl=$false;
          marker='ALL CHECKS PASSED: dmz_eg4s20_min_top'},
        @{name='science_font16';    top='tb_science_font16';    glbl=$false;
          marker='ALL CHECKS PASSED: science_font16'},
        # Board-level SDRAM frame BIST top: 50MHz in -> PLL -> controller ->
        # 153600-word write + read-back. ~385k cycles, about 2 minutes. Needs
        # glbl (PLL model) and SDRAM_SIM_MODEL (inline behavioural memory).
        @{name='sdram_frame_diag_top'; top='tb_sdram_frame_diag_top'; glbl=$true;
          marker='ALL CHECKS PASSED: sdram_frame_diag_top'},

        # --- v2 control layer -----------------------------------------------
        # Pure combinational 10-step brightness dimmer (no clock port at all).
        @{name='brightness_apply';  top='tb_brightness_apply';  glbl=$false;
          marker='ALL CHECKS PASSED: brightness_apply'},
        # Daily/science/emergency mode FSM: Key2 cycles, Key3 jumps, temperature
        # alarm enters emergency, leaving requires a confirmed Key3 double-press.
        @{name='mode_ctrl';         top='tb_mode_ctrl';         glbl=$false;
          marker='ALL CHECKS PASSED: mode_ctrl'},
        # One-key-one-module decoder: 10-step brightness/volume, 5-step
        # resolution/aspect, three independent layer switches, emergency clamp.
        @{name='key_router';        top='tb_key_router';        glbl=$false;
          marker='ALL CHECKS PASSED: key_router'},

        # --- v2 sensor layer -------------------------------------------------
        # I2C physical layer against a behavioural AHT20 slave model: START/
        # STOP/byte/ACK, open-drain semantics, 100kHz SCL period, edge-triggered
        # request handling.
        @{name='i2c_master';        top='tb_i2c_master';        glbl=$false;
          marker='ALL CHECKS PASSED: i2c_master'},
        # AHT20 protocol layer: trigger/read/CRC8, full-scale and zero boundary
        # values, NACK and CRC failure paths, sensor_fault fail-safe semantics.
        @{name='aht20_ctrl';        top='tb_aht20_ctrl';        glbl=$false;
          marker='ALL CHECKS PASSED: aht20_ctrl'},
        # Sensor-agnostic threshold/hysteresis/interlock layer: signed
        # comparison (negative temperatures must never look like heat) and
        # fail-safe hold when readings go stale.
        @{name='thermal_guard';     top='tb_thermal_guard';     glbl=$false;
          marker='ALL CHECKS PASSED: thermal_guard'},

        # --- v2 t6 audio path ------------------------------------------------
        # fat32_reader: short-name parameterisation. The 11-byte 8.3 target
        # name must hit BGM.WAV / ALARM.WAV / NARR.WAV / NARR.SRT / SCI.RLE
        # (lower-case on disk) while IMGnnn.BMP index addressing still works.
        @{name='fat32_reader';      top='tb_fat32_reader';      glbl=$false;
          marker='ALL CHECKS PASSED: fat32_reader'},
        # brightness vs volume gain direction. These two tables use the SAME
        # gain set {3,6,10,13,16,20,23,26,29,32}/32 in OPPOSITE order, so the
        # direction assertions must live in one testbench, side by side.
        @{name='gain_direction';    top='tb_gain_direction';    glbl=$false;
          marker='ALL CHECKS PASSED: gain_direction'},
        # vol_apply: 10-level table, emergency floor clamp, strict mute via
        # audio_en gate, and the negative-axis direction check that catches
        # an arithmetic shift (>>>) accidentally written as logical (>>).
        @{name='vol_apply';         top='tb_vol_apply';         glbl=$false;
          marker='ALL CHECKS PASSED: vol_apply'},
        # audio_src_mux: mode->source mapping, single-cycle src_start,
        # sd_ready gating, and emergency forced audio that never rewrites
        # the user's audio_en register.
        @{name='audio_src_mux';     top='tb_audio_src_mux';     glbl=$false;
          marker='ALL CHECKS PASSED: audio_src_mux'},
        # wav_stream_player: real RIFF/fmt/data chunk parsing, 520-cycle
        # fractional sample tick, underrun hold-last-sample, loop wraparound
        # back to the PCM start (not the file start).
        @{name='wav_stream_player'; top='tb_wav_stream_player'; glbl=$false;
          marker='ALL CHECKS PASSED: wav_stream_player'}
    )

    foreach ($case in $cases) {
        $log = $case.name + '.log'
        $script:A4Ran++

        $simArgs = @('-c', '-quiet', '-onfinish', 'stop',
                     '-do', 'onerror {quit -f -code 2}; onbreak {quit -f -code 3}; run -all; quit -f -code 0',
                     ('work.' + $case.top))
        if ($case.glbl) { $simArgs += 'glbl' }

        & (Join-Path $ModelSimPath 'vsim.exe') @simArgs *> $log
        $exit = $LASTEXITCODE

        $content   = [IO.File]::ReadAllText((Join-Path $ReportDir $log))
        $passLines = [regex]::Matches($content, '(?m)^\s*(?:#\s*)?PASS:').Count

        $knownIssues = 0
        $m = [regex]::Match($content, 'known_issues=(\d+)')
        if ($m.Success) { $knownIssues = [int]$m.Groups[1].Value }

        # Failure means: non-zero exit, missing marker, zero PASS lines, or any
        # FAIL / GLOBAL TIMEOUT / simulator error in the log.
        $bad = $content -match 'CHECKS FAILED|GLOBAL TIMEOUT|(?:^|\n)\s*(?:#\s*)?(?:FAIL\b|TIMEOUT:)|\*\*\s+(?:Error|Fatal)\b'
        $passed = ($exit -eq 0) -and $content.Contains($case.marker) -and
                  ($passLines -gt 0) -and (-not $bad)

        $result.tests += @{
            name        = $case.name
            top         = $case.top
            passed      = $passed
            exitCode    = $exit
            passLines   = $passLines
            knownIssues = $knownIssues
            usesGlbl    = [bool]$case.glbl
            log         = $log
            arguments   = @($simArgs)
        }

        $line = '{0,-22} passed={1,-6} passLines={2,-4} knownIssues={3}' -f `
                $case.name, $passed, $passLines, $knownIssues
        Write-Output $line
        if ($passed) { $script:A4Passed++ } else { $failed = $true }
    }

    # ---- Verify no source changed while the suite was running -------------
    foreach ($source in $hashes) {
        $now = (Get-FileHash -LiteralPath $source.path -Algorithm SHA256).Hash
        if ($now -ne $source.sha256) {
            throw ('Source changed during validation: ' + $source.path)
        }
    }

    # ---- A4 分母断言（t9 加）--------------------------------------------
    # 三条一起判，缺一不可：
    #   1) $script:A4Ran -gt 0              跑了没有
    #   2) $script:A4Ran -eq $ExpCaseCount  跑够没有（与硬编码期望数比，不同源自证）
    #   3) $script:A4Passed -eq $script:A4Ran 全过了没有
    # 只做 3) 时「一个没跑」也满足；只做 1)+3) 时「case 表被误删一半」也满足。
    if ($script:A4Ran -eq 0) {
        Write-Output ('  A4-GATE: ran=0（一个 case 都没跑却要打印 PASS，这是最该报警的状态）')
        $failed = $true
    }
    if ($script:A4Ran -ne $ExpCaseCount) {
        Write-Output ('  A4-GATE: ran=' + $script:A4Ran + ' 与期望 case 数 ' + $ExpCaseCount + ' 不符（case 表被改过？）')
        $failed = $true
    }
    if ($script:A4Passed -ne $script:A4Ran) {
        Write-Output ('  A4-GATE: passed=' + $script:A4Passed + ' / ran=' + $script:A4Ran)
        $failed = $true
    }
    Write-Output ('  A4-GATE: ran=' + $script:A4Ran + ' passed=' + $script:A4Passed + ' expected=' + $ExpCaseCount)

    $result.ran = $script:A4Ran
    $result.passedCount = $script:A4Passed
    $result.expectedCaseCount = $ExpCaseCount
    $result.status = $(if ($failed) { 'failed' } else { 'passed' })
}
catch {
    $failed = $true
    $result.status = 'failed'
    $result.error = $_.Exception.Message
    Write-Error -ErrorAction Continue $_
}
finally {
    $result.finishedAt = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath result.json -Encoding utf8
    Pop-Location
}

if ($failed) { exit 1 }
exit 0
