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
    'sim/testbench/tb_sdram_frame_diag_top.v'
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
          marker='ALL CHECKS PASSED: sdram_frame_diag_top'}
    )

    foreach ($case in $cases) {
        $log = $case.name + '.log'

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
        if (-not $passed) { $failed = $true }
    }

    # ---- Verify no source changed while the suite was running -------------
    foreach ($source in $hashes) {
        $now = (Get-FileHash -LiteralPath $source.path -Algorithm SHA256).Hash
        if ($now -ne $source.sha256) {
            throw ('Source changed during validation: ' + $source.path)
        }
    }

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
