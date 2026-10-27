# HDMI audio path regression: tone generator -> ACR -> PCM-to-PWM.
# Covers the audio chain that feeds BOTH the HDMI 1.4b transmitter core
# (audio samples + ACR packets) and the onboard PWM pin (F3).
[CmdletBinding()]
param(
    [string]$ModelSimPath = 'D:\Quartus_APP\modelsim_ase\win32aloem',
    [string]$ReportDir = 'reports\s6_integration\audio'
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not [IO.Path]::IsPathRooted($ReportDir)) { $ReportDir = Join-Path $root $ReportDir }
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$sources = @(
    'rtl/audio/audio_tone_gen.v',
    'rtl/video/hdmi/audio_arc.v',
    'rtl/audio/pcm_to_pwm.v',
    'rtl/audio/pwm_audio_out.v',
    'sim/testbench/tb_hdmi_audio_path.v',
    'sim/testbench/tb_pwm_audio_out.v'
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
        # The end-to-end chain: 48 kHz sample rate, ACR cadence, PWM duty,
        # per-state pitch (video/audio coupling) and mute semantics.
        @{name='hdmi_audio_path'; top='tb_hdmi_audio_path'; marker='ALL CHECKS PASSED: hdmi_audio_path'; arguments=@()},
        # Legacy PWM test tone module. It is no longer instantiated by the top
        # level (pcm_to_pwm replaced it) but stays in the source tree as the
        # documented rollback path, so it keeps its coverage.
        @{name='pwm_audio_out_legacy'; top='tb_pwm_audio_out'; marker='ALL CHECKS PASSED, errors = 0'; arguments=@()}
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
        # Two PASS conventions live in this tree: 'PASS: ...' (newer benches)
        # and 'PASS - ...' (tb_pwm_audio_out.v). Count the bare token, which
        # also can't match 'PASSED' because of the trailing word boundary.
        $checks = [regex]::Matches($content, '(?m)^\s*(?:#\s*)?PASS\b').Count
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
