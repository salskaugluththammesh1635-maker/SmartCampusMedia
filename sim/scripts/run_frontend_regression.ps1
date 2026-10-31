# Independent SD/FAT32/BMP/playback regression, with positive pass markers.
[CmdletBinding()]
param(
    [string]$ModelSimPath = 'D:\Quartus_APP\modelsim_ase\win32aloem',
    [string]$ReportDir = 'reports\s6_integration\frontend'
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not [IO.Path]::IsPathRooted($ReportDir)) { $ReportDir = Join-Path $root $ReportDir }
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$sources = @(
    'rtl/storage/sd_spi_ctrl.v', 'rtl/storage/sd_probe.v',
    'rtl/storage/fat32_reader.v', 'rtl/storage/gallery_probe.v',
    'rtl/storage/bmp_parser.v',
    'rtl/storage/img_loader.v', 'rtl/control/player_ctrl.v',
    'rtl/control/err_prompt.v', 'rtl/audio/buzzer_tone.v',
    'rtl/control/key_action.v', 'rtl/video/audio_waveform.v',
    'rtl/video/video_overlay.v',
    'sim/testbench/tb_sd_spi_protocol.v', 'sim/testbench/tb_sd_spi_ctrl.v',
    'sim/testbench/tb_sd_probe.v', 'sim/testbench/tb_fat32_reader.v',
    'sim/testbench/tb_gallery_probe.v',
    'sim/testbench/tb_bmp_parser.v', 'sim/testbench/tb_img_loader.v',
    'sim/testbench/tb_player_ctrl.v',
    'sim/testbench/tb_err_prompt.v', 'sim/testbench/tb_buzzer_tone.v',
    'sim/testbench/tb_key_action.v', 'sim/testbench/tb_video_overlay.v',
    'rtl/video/science_font16.v', 'rtl/video/science_page.v', 'rtl/video/video_content_mux.v',
    'sim/testbench/tb_science_page.v', 'sim/testbench/tb_video_content_mux.v',
    # B1 图层叠加与字幕：字模 ROM / 字符串表 / 字幕渲染器
    'rtl/osd/osd_font8x16.v', 'rtl/osd/osd_strings.v', 'rtl/osd/osd_caption.v',
    'sim/testbench/tb_osd_caption.v',
    # B3 实时参数 OSD：参数文字表 / 参数面板 / 变化自动弹窗
    # osd_font8x16 上面已列出，三个 B3 模块共用同一套字模。
    'rtl/osd/osd_param_text.v', 'rtl/osd/osd_panel.v', 'rtl/osd/osd_autopop.v',
    'sim/testbench/tb_osd_param_text.v', 'sim/testbench/tb_osd_panel.v',
    'sim/testbench/tb_osd_autopop.v',
    # B2 换帧转场混合器：纯组合像素缩放，独立单元验证
    'rtl/storage/fade_mixer.v', 'sim/testbench/tb_fade_mixer.v'
)
$hashes = @($sources | ForEach-Object {
    @{ path = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $root $_) -Algorithm SHA256).Hash }
})
$result = [ordered]@{ startedAt=(Get-Date).ToString('o'); status='running'; sources=$hashes; tests=@() }
$failed = $false
Push-Location $ReportDir
try {
    if (-not (Test-Path work)) {
        & "$ModelSimPath\vlib.exe" work *> vlib.txt
        if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    }
    & "$ModelSimPath\vlog.exe" -quiet @($sources | ForEach-Object { Join-Path $root $_ }) *> compile.txt
    if ($LASTEXITCODE -ne 0) { throw 'vlog failed; no stale simulation was run' }
    $cases = @(
        @{name='sd_protocol_default'; top='tb_sd_spi_protocol'; marker='ALL CHECKS PASSED: strict SD SPI protocol'; arguments=@()},
        @{name='sd_protocol_fast'; top='tb_sd_spi_protocol'; marker='ALL CHECKS PASSED: strict SD SPI protocol';
            arguments=@('-gINIT_DIV=2', '-gLOOP_LIMIT=4', '-gTOKEN_LIMIT=256', '-gPOWERUP_DELAY=100')},
        @{name='sd_spi_ctrl'; top='tb_sd_spi_ctrl'; marker='ALL CHECKS PASSED, errors = 0'; arguments=@()},
        @{name='sd_probe'; top='tb_sd_probe'; marker='*** ALL CHECKS PASSED ***'; arguments=@()},
        @{name='fat32_reader'; top='tb_fat32_reader'; marker='ALL CHECKS PASSED: fat32_reader'; arguments=@()},
        @{name='gallery_probe'; top='tb_gallery_probe'; marker='ALL CHECKS PASSED: gallery_probe'; arguments=@()},
        @{name='bmp_parser'; top='tb_bmp_parser'; marker='ALL CHECKS PASSED: bmp_parser'; arguments=@()},
        @{name='img_loader'; top='tb_img_loader'; marker='ALL CHECKS PASSED: img_loader'; arguments=@()},
        @{name='player_ctrl'; top='tb_player_ctrl'; marker='ALL CHECKS PASSED: player_ctrl'; arguments=@()},
        @{name='err_prompt'; top='tb_err_prompt'; marker='*** ALL CHECKS PASSED ***'; arguments=@()},
        @{name='buzzer_tone'; top='tb_buzzer_tone'; marker='*** ALL CHECKS PASSED ***'; arguments=@()},
        @{name='key_action'; top='tb_key_action'; marker='ALL CHECKS PASSED: key_action'; arguments=@()},
        @{name='video_overlay'; top='tb_video_overlay'; marker='ALL CHECKS PASSED: video_overlay'; arguments=@()},
        @{name='science_page'; top='tb_science_page'; marker='ALL CHECKS PASSED: science_page'; arguments=@()},
        @{name='video_content_mux'; top='tb_video_content_mux'; marker='ALL CHECKS PASSED: video_content_mux'; arguments=@()},
        @{name='osd_caption'; top='tb_osd_caption'; marker='ALL CHECKS PASSED: osd_caption'; arguments=@()},
        @{name='osd_param_text'; top='tb_osd_param_text'; marker='ALL CHECKS PASSED: osd_param_text'; arguments=@()},
        @{name='osd_panel'; top='tb_osd_panel'; marker='ALL CHECKS PASSED: osd_panel'; arguments=@()},
        @{name='osd_autopop'; top='tb_osd_autopop'; marker='ALL CHECKS PASSED: osd_autopop'; arguments=@()},
        @{name='fade_mixer'; top='tb_fade_mixer'; marker='ALL CHECKS PASSED: fade_mixer'; arguments=@()}
    )
    foreach ($case in $cases) {
        $log = $case.name + '.txt'
        $simArgs = @('-c', '-quiet', '-onfinish', 'stop') + $case.arguments + @(
            '-do', 'onerror {quit -f -code 2}; onbreak {quit -f -code 3}; run -all; quit -f -code 0',
            ('work.' + $case.top)
        )
        & "$ModelSimPath\vsim.exe" @simArgs *> $log
        $exit = $LASTEXITCODE
        $content = [IO.File]::ReadAllText((Join-Path $ReportDir $log))
        $checks = [regex]::Matches($content, '(?m)^\s*(?:#\s*)?PASS:').Count
        $bad = $content -match 'CHECKS FAILED|GLOBAL TIMEOUT|(?:^|\n)\s*(?:#\s*)?(?:FAIL\b|TIMEOUT:)|\*\*\s+(?:Error|Fatal)\b'
        $passed = $exit -eq 0 -and $content.Contains($case.marker) -and $checks -gt 0 -and -not $bad
        $result.tests += @{ name=$case.name; passed=$passed; exitCode=$exit; passLines=$checks; log=$log; arguments=@($simArgs) }
        Write-Output ($case.name + ': passed=' + $passed + '; passLines=' + $checks)
        if (-not $passed) { $failed = $true }
    }
    foreach ($source in $hashes) {
        if ((Get-FileHash -LiteralPath (Join-Path $root $source.path) -Algorithm SHA256).Hash -ne $source.sha256) {
            throw ('Source changed during validation: ' + $source.path)
        }
    }
    $result.status = $(if ($failed) { 'failed' } else { 'passed' })
}
catch { $failed=$true; $result.status='failed'; $result.error=$_.Exception.Message; Write-Error -ErrorAction Continue $_ }
finally {
    $result.finishedAt=(Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath result.json -Encoding utf8
    Pop-Location
}
if ($failed) { exit 1 }
exit 0
