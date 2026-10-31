# =============================================================================
# run_full_regression.ps1
# -----------------------------------------------------------------------------
# One command to run EVERY simulation suite in this repository and print a single
# pass/fail table.
#
#   powershell -ExecutionPolicy Bypass -File sim\scripts\run_full_regression.ps1
#   pwsh -File sim\scripts\run_full_regression.ps1 -Suite unit
#
# Suites (each is one existing script; this driver only orchestrates):
#   unit        run_unit_coverage_regression.ps1  18 module testbenches (NEW)
#   frontend    run_frontend_regression.ps1       SD/FAT32/BMP/player/OSD (20 TB)
#   storage     run_storage_regression.ps1        SDRAM/framebuf/retention
#   audio       run_audio_regression.ps1          audio path
#   startup     run_startup_ownership_regression.ps1  startup ownership
#   display     run_display_content.ps1           display content
#   image       run_image_regression.ps1          image path
#
# ORDER MATTERS ONLY FOR READABILITY - suites are independent. Each suite gets
# its own report directory and its own ModelSim work library.
#
# REPORT DIRECTORY
#   Defaults to <temp>\scm_full_regression\<suite>. Sub-directories cannot be
#   created inside the repository in this environment, so a temp default is the
#   only one that works out of the box. Override with -ReportRoot if your
#   checkout allows repo-local output.
# =============================================================================
[CmdletBinding()]
param(
    [string]$ModelSimPath = 'D:\Quartus_APP\modelsim_ase\win32aloem',
    [string]$PrimLibPath  = 'D:\TD_6_24_APP\sim_release\eg4',
    [string]$ReportRoot   = (Join-Path $env:TEMP 'scm_full_regression'),
    # Comma separated subset, e.g. -Suite unit,frontend. Empty means all.
    [string[]]$Suite      = @(),
    # Keep going after a failing suite and report the whole table.
    [switch]$ContinueOnError
)

$ErrorActionPreference = 'Stop'

$repoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$scriptsDir   = Join-Path $repoRoot 'sim\scripts'
New-Item -ItemType Directory -Force -Path $ReportRoot | Out-Null

# ---- Suite table -----------------------------------------------------------
#   script : file name under sim\scripts
#   title  : one-line description shown in the summary
#   extra  : extra arguments appended to the child invocation (optional)
$allSuites = @(
    @{ name='unit';     script='run_unit_coverage_regression.ps1';      title='18 module unit testbenches';            extra=@() },
    @{ name='frontend'; script='run_frontend_regression.ps1';           title='SD/FAT32/BMP/player/OSD';               extra=@() },
    @{ name='storage';  script='run_storage_regression.ps1';            title='SDRAM / framebuf / retention';          extra=@() },
    @{ name='audio';    script='run_audio_regression.ps1';              title='audio tone / PWM / waveform path';      extra=@() },
    @{ name='startup';  script='run_startup_ownership_regression.ps1';  title='startup ownership handoff';             extra=@() },
    @{ name='display';  script='run_display_content.ps1';               title='display content verification';          extra=@() },
    @{ name='image';    script='run_image_regression.ps1';              title='image path regression';                 extra=@() }
)

# ---- Select the suites to run ---------------------------------------------
if ($Suite.Count -gt 0) {
    $wanted = @($Suite | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $unknown = @($wanted | Where-Object { $_ -notin @($allSuites | ForEach-Object { $_.name }) })
    if ($unknown.Count -gt 0) {
        throw ("Unknown suite(s): " + ($unknown -join ', ') +
               ". Known suites: " + (($allSuites | ForEach-Object { $_.name }) -join ', '))
    }
    $selected = @($allSuites | Where-Object { $_.name -in $wanted })
} else {
    $selected = $allSuites
}

# ---- Preflight -------------------------------------------------------------
foreach ($tool in @('vlib', 'vlog', 'vsim')) {
    $exe = Join-Path $ModelSimPath ($tool + '.exe')
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "Missing ModelSim tool: $tool.exe under $ModelSimPath"
    }
}

$results  = @()
$failed   = $false
$startedAt = Get-Date

foreach ($s in $selected) {
    $scriptPath = Join-Path $scriptsDir $s.script
    $reportDir  = Join-Path $ReportRoot $s.name

    Write-Output ''
    Write-Output ('=== [' + $s.name + '] ' + $s.title + ' ===')

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-Output ('  SKIP: script not found: ' + $s.script)
        $results += @{ name=$s.name; title=$s.title; status='missing'; exitCode=$null;
                       seconds=0; passLines=0; reportDir=$reportDir; note=('missing ' + $s.script) }
        $failed = $true
        continue
    }

    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    $consoleLog = Join-Path $reportDir 'console.log'
    $t0 = Get-Date

    # Child scripts accept -ModelSimPath / -ReportDir uniformly.
    $childArgs = @('-ModelSimPath', $ModelSimPath, '-ReportDir', $reportDir) + @($s.extra)

    # Run in a separate PowerShell process so one suite's Push-Location or
    # preference changes cannot leak into the next one.
    $psExe = (Get-Process -Id $PID).Path
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @childArgs *> $consoleLog
    $code = $LASTEXITCODE
    $secs = [int]((Get-Date) - $t0).TotalSeconds

    $console = ''
    if (Test-Path -LiteralPath $consoleLog) { $console = [IO.File]::ReadAllText($consoleLog) }

    # A suite counts as passed when it exits 0 and never printed a FAIL line.
    $sawFail = $console -match '(?m)^\s*(?:#\s*)?FAIL\b|CHECKS FAILED|GLOBAL TIMEOUT|\*\*\s+(?:Error|Fatal)\b'
    $status  = if (($code -eq 0) -and (-not $sawFail)) { 'passed' } else { 'failed' }
    if ($status -eq 'failed') { $failed = $true }

    # Count the assertions this suite actually verified. The console of a suite
    # script only carries its own summary table, so the numbers have to come
    # from its result.json. The existing suites do not share one schema, so try
    # every field name a suite might use before giving up.
    $suitePassLines = 0

    # Surface the per-suite result.json status when the script wrote one.
    $note = ''
    $rj = Join-Path $reportDir 'result.json'
    if (Test-Path -LiteralPath $rj) {
        try {
            $j = Get-Content -LiteralPath $rj -Raw | ConvertFrom-Json
            $note = 'result.json status=' + $j.status
            if ($j.PSObject.Properties.Name -contains 'tests') {
                # Some suites record a boolean `passed`, others a `status` string.
                $n = @($j.tests).Count
                $p = @($j.tests | Where-Object {
                    ($_.PSObject.Properties.Name -contains 'passed' -and $_.passed) -or
                    ($_.PSObject.Properties.Name -contains 'status' -and $_.status -eq 'passed')
                }).Count
                $note += (' tests=' + $p + '/' + $n)

                # Assertion count per test: `passLines` in the legacy suites,
                # `checks` in the diagnostic ones.
                foreach ($t in @($j.tests)) {
                    if ($t.PSObject.Properties.Name -contains 'passLines' -and $t.passLines) {
                        $suitePassLines += [int]$t.passLines
                    } elseif ($t.PSObject.Properties.Name -contains 'checks' -and $t.checks) {
                        $suitePassLines += [int]$t.checks
                    }
                }
            }
            # Suites that report a single aggregate count instead of per-test rows.
            if (($suitePassLines -eq 0) -and ($j.PSObject.Properties.Name -contains 'checks') -and $j.checks) {
                $suitePassLines = [int]$j.checks
                $note += (' checks=' + $j.checks)
                if ($j.PSObject.Properties.Name -contains 'errors') { $note += (' errors=' + $j.errors) }
            }
        } catch { $note = 'result.json unreadable' }
    }

    # Fallback for suites that write no result.json (startup ownership): count
    # the "# PASS:" lines they leave in their own per-case logs.
    if ($suitePassLines -eq 0) {
        foreach ($lg in @(Get-ChildItem -LiteralPath $reportDir -Filter '*.log' -File -ErrorAction SilentlyContinue)) {
            $txt = [IO.File]::ReadAllText($lg.FullName)
            $suitePassLines += [regex]::Matches($txt, '(?m)^\s*(?:#\s*)?PASS:').Count
        }
    }

    if ($suitePassLines -gt 0) { $note += (' asserts=' + $suitePassLines) }

    Write-Output ('  ' + $status + '  exit=' + $code + '  ' + $secs + 's  ' + $note)

    $results += @{ name=$s.name; title=$s.title; status=$status; exitCode=$code;
                   seconds=$secs; passLines=$suitePassLines; reportDir=$reportDir; note=$note }

    if (($status -eq 'failed') -and (-not $ContinueOnError)) {
        Write-Output '  stopping after first failure (use -ContinueOnError to run all)'
        break
    }
}

# ---- Summary table ---------------------------------------------------------
$elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
Write-Output ''
Write-Output '================ FULL REGRESSION SUMMARY ================'
$results | ForEach-Object {
    '{0,-10} {1,-8} exit={2,-6} {3,5}s  asserts={4,-7} {5}' -f `
        $_.name, $_.status.ToUpper(), $(if ($null -eq $_.exitCode) { 'n/a' } else { $_.exitCode }),
        $_.seconds, $_.passLines, $_.title
}
Write-Output ('--------------------------------------------------------')
$pass = @($results | Where-Object { $_.status -eq 'passed' }).Count
$totalPassLines = (@($results | ForEach-Object { $_.passLines }) | Measure-Object -Sum).Sum
if (-not $totalPassLines) { $totalPassLines = 0 }
Write-Output ('suites: passed=' + $pass + ' failed=' + (@($results).Count - $pass) +
              ' total=' + @($results).Count + '  asserts=' + $totalPassLines +
              '  elapsed=' + $elapsed + 's')

# ---- Machine readable summary ---------------------------------------------
$summary = [ordered]@{
    startedAt  = $startedAt.ToString('o')
    finishedAt = (Get-Date).ToString('o')
    status     = $(if ($failed) { 'failed' } else { 'passed' })
    modelSimPath = $ModelSimPath
    primLibPath  = $PrimLibPath
    reportRoot   = $ReportRoot
    elapsedSeconds = $elapsed
    totalPassLines = $totalPassLines
    suites     = $results
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $ReportRoot 'summary.json') -Encoding utf8

if ($failed) {
    Write-Output 'FULL REGRESSION FAILED'
    exit 1
}
Write-Output 'FULL REGRESSION PASSED'
exit 0
