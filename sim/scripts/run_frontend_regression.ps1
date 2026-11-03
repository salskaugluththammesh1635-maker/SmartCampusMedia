# Independent SD/FAT32/BMP/playback regression, with positive pass markers.
[CmdletBinding()]
param(
    [string]$ModelSimPath = 'D:\Quartus_APP\modelsim_ase\win32aloem',
    [string]$ReportDir = 'reports\s6_integration\frontend',
    # vlog 编译宏（本套件所有 case 共用）
    #
    #   +define+SDRAM_SIM_MODEL
    #     让 rtl/storage/sdram_ctrl_wrap.v 例化文件内自带的行为模型，而不是
    #     Anlogic 加密核（ip/local/sdram/sdr_as_ram.enc.v）。ModelSim ASE 根本
    #     编不动那个加密核 —— vlog 直接 exit=2（"Macro DATA_WIDTH is undefined"
    #     / "protected region"）。sdram_ctrl_wrap.v:25-40 的头注写明了：仿真与
    #     综合只能靠「文件级二选一 + 这个宏」分开。
    #     本套件当前的 21 个 case 没有一个例化 sdram_ctrl_wrap，所以这个宏在此
    #     处是惰性的；默认打开是为了让 t9 的三个主力脚本（full / frontend /
    #     audio）行为一致，也为了将来某个端到端 case（image_player ->
    #     sdram_ctrl_wrap）不会悄悄把加密核拖进来。run_unit_coverage_regression.ps1
    #     从 2026-11-01 起就用这个宏编译它的全部 29 个 unit case 并且全绿，
    #     这本身就是「该宏对非 SDRAM 模块无害」的现成证据。
    [string[]]$VlogDefines = @('+define+SDRAM_SIM_MODEL')
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
    # science_page.v / science_font16.v 已从本套件摘除（2026-11-02，t16 裁定）。
    # 科普模式现为「RLE 视频走 video_content_mux」，顶层 u_science_page 已删除，
    # 资源表已计 -664 LUT，这两个 .v 与 tb_science_page.v 都成了孤儿。留着这条
    # case 有两个实际害处：
    #   ① 它测的模块不再被任何顶层例化，绿了也不代表任何功能在测，反而让人
    #      误以为「科普静态页」还在；
    #   ② 它会把这两个孤儿文件塞进下面的 $hashes 指纹，等 t11 清理孤儿文件时，
    #      回归会以 throw('Source changed during validation: ...') 的方式整套
    #      失败，而不是给出一条可读提示。
    # 三个文件本身保留（删不删由 t11 决定），这里只摘掉回归入口。
    'rtl/video/video_content_mux.v',
    'sim/testbench/tb_video_content_mux.v',
    # B1 图层叠加与字幕：字模 ROM / 字符串表 / 字幕渲染器
    #   osd_caption.v 自 t13 起例化了 narr_subline（中文滚动字幕行序列）与
    #   cjk16_font（16x16 汉字点阵 ROM），两者必须一起编译，否则 osd_caption
    #   的例化会 elaborate 失败（vsim-3033 "The design unit was not found"），
    #   连带 tb_video_overlay / tb_osd_caption / tb_osd_caption_cjk 全部挂掉。
    'rtl/osd/narr_subline.v',
    'rtl/osd/osd_font8x16.v', 'rtl/osd/osd_strings.v', 'rtl/osd/osd_caption.v',
    'rtl/osd/cjk16_font.v',
    'sim/testbench/tb_osd_caption.v',
    # t21 中文滚动字幕：词表/行序列 ROM + 汉字点阵 + 渲染器全链路
    #   这条 tb 的 marker 前缀带 tb_（ALL CHECKS PASSED: tb_osd_caption_cjk），
    #   与其它 tb 的 "ALL CHECKS PASSED: <name>" 风格不同，照它实际打印的写。
    'sim/testbench/tb_osd_caption_cjk.v',
    # t13 B-lite 中文滚动字幕行序列：narr_subline 是叶子模块（无子模块依赖），
    # 但它和 cjk 那条一样是「通过时一行不打」的判分风格，所以 case 里必须带
    # checksFromSummary=$true，否则 PASS: 行计数恒 0 -> 永远判失败。
    'sim/testbench/tb_narr_subline.v',
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
# $readmemh 读的字模表也纳入指纹：它进不了 vlog 的源列表（不是 .v），
# 但 tb 的判定完全依赖它的内容，改坏了必须能被 result.json 抓到。
foreach ($hexAsset in @('rtl/osd/cjk16_bitmap.hex')) {
    $hashes += @{ path = $hexAsset; sha256 = (Get-FileHash -LiteralPath (Join-Path $root $hexAsset) -Algorithm SHA256).Hash }
}
$result = [ordered]@{ startedAt=(Get-Date).ToString('o'); status='running'; sources=$hashes; tests=@() }
$failed = $false

# ---- A4 分母断言（t9 加）---------------------------------------------------
# 只断言「没有失败」在「一个 case 都没跑」时同样成立，而「一个 case 都没跑」
# 恰恰是最该报警的状态。收尾必须同时断言分母三件事：
#   1) $script:A4Ran -gt 0               真的跑了
#   2) $script:A4Ran -eq $ExpCaseCount   跑够没有（与下面的期望数比，不同源自证）
#   3) $script:A4Passed -eq $script:A4Ran  全过了没有
# 必须用 $script: 前缀：将来若把主循环包进函数，函数里的 += 改的是局部副本，
# 外层判据会永远看到 0 → 照样打印 PASS（scripts\run_tb_baseline.ps1 头注记着这坑）。
# 期望数是**硬编码**的、刻意不用 @($cases).Count：后者是同源自证，case 表被误删
# 时期望值会跟着一起变小，断言永远成立、永远抓不到。
$script:A4Ran    = 0
$script:A4Passed = 0
$ExpCaseCount  = 21   # frontend 套件应有 case 数；tb 增删必须同步改这里

Push-Location $ReportDir
try {
    if (-not (Test-Path work)) {
        & "$ModelSimPath\vlib.exe" work *> vlib.txt
        if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    }
    # ------------------------------------------------------------------
    # $readmemh 的 cwd 陷阱（缺口 B）
    #
    # rtl/osd/cjk16_font.v:98 写的是裸相对路径：
    #     $readmemh("cjk16_bitmap.hex", mem);
    # ModelSim 按 **vsim 启动时的当前工作目录** 解析它，而 TD 综合期是按
    # 「调用 $readmemh 的 .v 所在目录 -> .al 所在目录」解析。两套规则不同，
    # 于是同一个工程在综合里能过、在仿真里静默读空表。
    #
    # 读不到时不会报错退出，只打一条 warning 然后继续跑，点阵全 0：
    #   # ** Warning: (vsim-7) Failed to open readmem file "cjk16_bitmap.hex" in read mode.
    #   # No such file or directory. (errno = ENOENT)    : .../rtl/osd/cjk16_font.v(98)
    # 每个 cjk16_font 例化各打一条（tb_osd_caption_cjk 里有 4 个例化 = 4 条），
    # 随后断言报 "[FAIL] C01 ... got=16'h0000 exp=16'h3ff8" 共 5 条。
    # 后来人看到这条 warning 请直接判定为路径问题，不要去查 RTL。
    #
    # 注意：拷到 work\ 子目录没用 —— 解析基准是 cwd 而不是 work 库目录，
    # 上面 Push-Location 之后 cwd 就是 $ReportDir，所以目标就是这里。
    # 跑完不清理：.hex 留在报告目录里无害，下次覆盖写。
    # 任何新的 cjk16_font 使用者（含例化 osd_caption 的 tb）都靠这段自动就位。
    # ------------------------------------------------------------------
    $hexAssets = @('rtl/osd/cjk16_bitmap.hex')
    foreach ($hex in $hexAssets) {
        $hexSrc = Join-Path $root $hex
        if (-not (Test-Path -LiteralPath $hexSrc)) { throw ('missing readmem asset: ' + $hex) }
        Copy-Item -LiteralPath $hexSrc -Destination (Join-Path $ReportDir (Split-Path $hex -Leaf)) -Force
    }
    & "$ModelSimPath\vlog.exe" -quiet @VlogDefines @($sources | ForEach-Object { Join-Path $root $_ }) *> compile.txt
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
        # 科普静态页已废弃（t16 裁定，顶层已删该实例），case 一并摘除。
        # 保留它只会让「绿」失去含义，并把孤儿文件拖进源指纹。
        @{name='video_content_mux'; top='tb_video_content_mux'; marker='ALL CHECKS PASSED: video_content_mux'; arguments=@()},
        @{name='osd_caption'; top='tb_osd_caption'; marker='ALL CHECKS PASSED: osd_caption'; arguments=@()},
        @{name='osd_param_text'; top='tb_osd_param_text'; marker='ALL CHECKS PASSED: osd_param_text'; arguments=@()},
        @{name='osd_panel'; top='tb_osd_panel'; marker='ALL CHECKS PASSED: osd_panel'; arguments=@()},
        @{name='osd_autopop'; top='tb_osd_autopop'; marker='ALL CHECKS PASSED: osd_autopop'; arguments=@()},
        # t21 中文滚动字幕：osd_caption（ASCII + cjk + 滚动叙述行）全键位验证，
        # 外加 4 个点阵 ROM 参考模型。marker 照它实际打印的写（前缀带 tb_），
        # 不要"统一"成 osd_caption_cjk。
        @{name='osd_caption_cjk'; top='tb_osd_caption_cjk'; marker='ALL CHECKS PASSED: tb_osd_caption_cjk';
            arguments=@(); checksFromSummary=$true},
        # narr_subline：marker 同 cjk 一样带 tb_ 前缀，判分风格也一样（通过时
        # 一行不打，收尾打「检查项 N 个，失败 M 个」），故必须 checksFromSummary。
        @{name='narr_subline'; top='tb_narr_subline'; marker='ALL CHECKS PASSED: tb_narr_subline';
            arguments=@(); checksFromSummary=$true},
        @{name='fade_mixer'; top='tb_fade_mixer'; marker='ALL CHECKS PASSED: fade_mixer'; arguments=@()}
    )
    foreach ($case in $cases) {
        $script:A4Ran++
        $log = $case.name + '.txt'
        $simArgs = @('-c', '-quiet', '-onfinish', 'stop') + $case.arguments + @(
            '-do', 'onerror {quit -f -code 2}; onbreak {quit -f -code 3}; run -all; quit -f -code 0',
            ('work.' + $case.top)
        )
        & "$ModelSimPath\vsim.exe" @simArgs *> $log
        $exit = $LASTEXITCODE
        $content = [IO.File]::ReadAllText((Join-Path $ReportDir $log))
        # 本仓库的 tb 有两种判分风格，计数方式必须跟着切换：
        #
        # 【风格 1】每断言打一行 "PASS: xxx"（绝大多数 tb）-> 直接数 PASS: 行。
        #
        # 【风格 2】只在失败时打 "[FAIL] ..."，通过时一行不打，收尾是
        #     ====...
        #      检查项 %0d 个，失败 %0d 个      <- 紧贴 marker 上一行
        #      ALL CHECKS PASSED: <marker>
        #     ====...
        # 目前有两条属于风格 2：tb_osd_caption_cjk、tb_narr_subline
        # （case 定义里用 checksFromSummary=$true 标记）。
        # 对它们数 PASS: 行恒得 0 -> $checks -gt 0 为假 -> 永远判失败，
        # 而且输出看起来像「tb 什么都没跑」。
        #
        # 风格 2 的统计行是中文，vsim 控制台把非 ASCII 打成 '?'
        # （实测日志里是 "#  ?????? 54585 ??????? 0 ???"），拿中文正则去匹配必然
        # 失配。所以这里不匹配文案，而是从 marker 行往上找最近一行含 >=2 个
        # 阿拉伯数字的，抠出「总数, 失败数」：数字是 ASCII，不受编码影响，
        # 也不依赖固定行偏移（cjk 差 1 行、narr 差 2 行，都在下面的 4 行窗口内）。
        if ($case.ContainsKey('checksFromSummary')) {
            $lines = $content -split "`r?`n"
            $checks = 0
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if (-not $lines[$i].Contains($case.marker)) { continue }
                for ($j = $i - 1; $j -ge 0 -and $j -ge $i - 4; $j--) {
                    $nums = @([regex]::Matches($lines[$j], '\d+') | ForEach-Object { [int]$_.Value })
                    if ($nums.Count -ge 2) {
                        # 统计行是「检查项 N 个，失败 M 个」；只有 M == 0 才算全过
                        if ($nums[1] -eq 0) { $checks = $nums[0] }
                        break
                    }
                }
                break
            }
        } else {
            $checks = [regex]::Matches($content, '(?m)^\s*(?:#\s*)?PASS:').Count
        }
        # 防御：marker 命中了却抠不出 check 数，说明这条 tb 的判分风格没被本脚本
        # 覆盖（它不是逐条打 "PASS:"、统计行里也没有「N ... M」两个数字）。
        # 此时 $checks 恒 0 -> $passed 恒 False，表面上像「tb 没跑出东西」，
        # 很容易被误判成 tb 挂了。给出明确诊断，别让它静默判红。
        if ($checks -eq 0 -and $content.Contains($case.marker)) {
            Write-Output ('  WARN: marker hit but no check count parsed; PASS:-line counting probably does not apply to this tb')
        }
        $bad = $content -match 'CHECKS FAILED|GLOBAL TIMEOUT|(?:^|\n)\s*(?:#\s*)?(?:FAIL\b|TIMEOUT:)|\*\*\s+(?:Error|Fatal)\b'
        $passed = $exit -eq 0 -and $content.Contains($case.marker) -and $checks -gt 0 -and -not $bad
        $result.tests += @{ name=$case.name; passed=$passed; exitCode=$exit; passLines=$checks; log=$log; arguments=@($simArgs) }
        Write-Output ($case.name + ': passed=' + $passed + '; passLines=' + $checks)
        if ($passed) { $script:A4Passed++ } else { $failed = $true }
    }
    foreach ($source in $hashes) {
        if ((Get-FileHash -LiteralPath (Join-Path $root $source.path) -Algorithm SHA256).Hash -ne $source.sha256) {
            throw ('Source changed during validation: ' + $source.path)
        }
    }
    # ---- A4 分母断言（t9 加）--------------------------------------------
    if ($script:A4Ran -eq 0) {
        Write-Output ('  A4-GATE: ran=0（一个 case 都没跑却要打印通过，这是最该报警的状态）')
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
catch { $failed=$true; $result.status='failed'; $result.error=$_.Exception.Message; Write-Error -ErrorAction Continue $_ }
finally {
    $result.finishedAt=(Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath result.json -Encoding utf8
    Pop-Location
}
if ($failed) { exit 1 }
exit 0
