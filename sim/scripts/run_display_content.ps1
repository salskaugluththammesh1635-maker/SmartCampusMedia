# Real BMP -> FAT32/BMP/FIFO/SDRAM/pixel_reader -> full-frame comparison.
[CmdletBinding()]
param(
    [string]$BmpPath = 'assets\sd_verify\good\IMG001.BMP',
    [string]$Bmp2Path = 'assets\sd_verify\good\IMG002.BMP',
    [int]$ByteGap = 1,
    [int]$ReloadCount = 0,
    [int]$ArbiterTurnGap = 3,
    [switch]$RealCore,
    [switch]$DatasheetTiming,
    [switch]$CoreReplay,
    [int]$ReplayShortGap = 12,
    [int]$ReplayFirstGroup = 0,
    [int]$ReplayGroups = 16,
    [switch]$SweepReadGaps,
    [string]$ModelSimPath = 'D:\Quartus_APP\modelsim_ase\win32aloem',
    [string]$ReportDir = 'reports\display_diag_20261028'
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not [IO.Path]::IsPathRooted($BmpPath)) { $BmpPath = Join-Path $root $BmpPath }
if (-not (Test-Path -LiteralPath $BmpPath -PathType Leaf)) {
    if ($PSBoundParameters.ContainsKey('BmpPath')) { throw "Specified BmpPath does not exist or is not a file: $BmpPath" }
    throw "Default verification BMP is missing: $BmpPath. Generate it from the repository root with: powershell -ExecutionPolicy Bypass -File scripts/prepare_board_verify_assets.ps1"
}
if (-not [IO.Path]::IsPathRooted($Bmp2Path)) { $Bmp2Path = Join-Path $root $Bmp2Path }
if (-not (Test-Path -LiteralPath $Bmp2Path -PathType Leaf)) {
    throw "Second verification BMP is missing: $Bmp2Path"
}
if (-not [IO.Path]::IsPathRooted($ReportDir)) { $ReportDir = Join-Path $root $ReportDir }
if ($DatasheetTiming -and -not $RealCore) { throw 'DatasheetTiming requires RealCore' }
if($CoreReplay -and -not $RealCore) { throw 'CoreReplay requires RealCore' }
if($SweepReadGaps -and -not $CoreReplay) { throw 'SweepReadGaps requires CoreReplay' }
if ($RealCore) {
    $ReportDir=Join-Path $ReportDir $(if($DatasheetTiming){'real_core_datasheet'}else{'real_core_functional'})
    $ModelSimPath='D:\MentorGraphics\HLVX.2.13\SDD_HOME\hyperlynx64\Ams\pkgs\icx_pro_sim\22.1\questasim\v2022.1\win64'
}
if($CoreReplay) { $ReportDir=Join-Path $ReportDir 'core_replay' }
if($SweepReadGaps) { $ReportDir=Join-Path $ReportDir 'gap_sweep' }
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
if ($ByteGap -lt 1) { throw 'ByteGap must be >=1. Use 15 for one byte per 16 pixel clocks (12.5MHz SPI).' }
if ($ReloadCount -lt 0) { throw 'ReloadCount must be >=0' }
if ($ArbiterTurnGap -lt 0 -or $ArbiterTurnGap -gt 255) { throw 'ArbiterTurnGap must be between 0 and 255' }

# C# keeps byte/pixel fixture generation fast and independent of the RTL parser.
if (-not ('DisplayContentFixture' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
public static class DisplayContentFixture {
  static void W16(byte[] d,int p,int v) { d[p]=(byte)v; d[p+1]=(byte)(v>>8); }
  static void W32(byte[] d,int p,int v) { for(int i=0;i<4;i++) d[p+i]=(byte)(v>>(8*i)); }
  static void CheckBmp(byte[] bmp) {
    int w=BitConverter.ToInt32(bmp,18), h=BitConverter.ToInt32(bmp,22);
    int off=BitConverter.ToInt32(bmp,10), stride=(w*3+3)&~3;
    if(bmp[0]!=66 || bmp[1]!=77 || w!=640 || Math.Abs(h)!=480 ||
       BitConverter.ToInt16(bmp,28)!=24 || BitConverter.ToInt32(bmp,30)!=0 ||
       off<54 || off+stride*Math.Abs(h)>bmp.Length) throw new Exception("Fixture must be a complete uncompressed 640x480 24bit BMP");
  }
  static void DirEntry(byte[] disk,int off,string name,int first,int length) {
    byte[] n=Encoding.ASCII.GetBytes(name);
    Array.Copy(n,0,disk,off,11); disk[off+11]=32;
    W16(disk,off+26,first); W32(disk,off+28,length);
  }
  static void Chain(byte[] disk,int fat,int first,int clusters) {
    for(int i=0;i<clusters;i++) W32(disk,fat*512+(first+i)*4,i==clusters-1?unchecked((int)0x0FFFFFF8):first+i+1);
  }
  static void CopyFile(byte[] disk,byte[] bmp,int first) {
    int sector=21+(first-2)*8;
    Buffer.BlockCopy(bmp,0,disk,sector*512,bmp.Length);
  }
  static void Golden(byte[] bmp,string path,string ppmPath) {
    int h=BitConverter.ToInt32(bmp,22), off=BitConverter.ToInt32(bmp,10), stride=(640*3+3)&~3;
    var hex=new StringBuilder(640*480*5); byte[] ppm=new byte[640*480*3];
    for(int y=0;y<480;y++) for(int x=0;x<640;x++) {
      int p=off+(h>0?479-y:y)*stride+x*3;
      int r=bmp[p+2]>>3,g=bmp[p+1]>>2,b=bmp[p]>>3;
      int rgb=(r<<11)|(g<<5)|b;
      hex.Append(rgb.ToString("x4")).Append('\n');
      int q=(y*640+x)*3; ppm[q]=(byte)((r<<3)|(r>>2));
      ppm[q+1]=(byte)((g<<2)|(g>>4)); ppm[q+2]=(byte)((b<<3)|(b>>2));
    }
    File.WriteAllText(path,hex.ToString(),Encoding.ASCII);
    if(ppmPath!=null) using(var fs=File.Create(ppmPath)) {
      byte[] header=Encoding.ASCII.GetBytes("P6\n640 480\n255\n");
      fs.Write(header,0,header.Length); fs.Write(ppm,0,ppm.Length);
    }
  }
  public static string Build(string source,string source2,string dir) {
    byte[] bmp=File.ReadAllBytes(source), bmp2=File.ReadAllBytes(source2);
    CheckBmp(bmp); CheckBmp(bmp2);
    byte[] disk=new byte[4096*512];
    // Two root-directory files share the minimal FAT32 layout used by tb_image_player FULL.
    disk[450]=12; W32(disk,454,4); W32(disk,458,4092); W16(disk,510,0xAA55);
    int v=4*512; W16(disk,v+11,512); disk[v+13]=8; W16(disk,v+14,1);
    disk[v+16]=2; W32(disk,v+36,8); W32(disk,v+44,2); W16(disk,v+510,0xAA55);
    int clusters=(bmp.Length+4095)/4096, clusters2=(bmp2.Length+4095)/4096;
    int first1=4, first2=first1+clusters;
    for(int fat=5;fat<=13;fat+=8) {
      W32(disk,fat*512,unchecked((int)0x0FFFFFF8)); W32(disk,fat*512+4,-1);
      W32(disk,fat*512+8,0x0FFFFFF8);
      Chain(disk,fat,first1,clusters); Chain(disk,fat,first2,clusters2);
    }
    DirEntry(disk,21*512,"IMG001  BMP",first1,bmp.Length);
    DirEntry(disk,21*512+32,"IMG002  BMP",first2,bmp2.Length);
    CopyFile(disk,bmp,first1); CopyFile(disk,bmp2,first2);
    var hex=new StringBuilder(disk.Length*3);
    foreach(byte value in disk) hex.Append(value.ToString("x2")).Append('\n');
    File.WriteAllText(Path.Combine(dir,"disk.hex"),hex.ToString(),Encoding.ASCII);
    Golden(bmp,Path.Combine(dir,"golden.hex"),Path.Combine(dir,"expected.ppm"));
    Golden(bmp2,Path.Combine(dir,"golden2.hex"),null);
    return "BMP1 bytes="+bmp.Length+" clusters="+clusters+" BMP2 bytes="+bmp2.Length+" clusters2="+clusters2+" width=640 height=480";
  }
}
'@
}
$fixtureInfo = [DisplayContentFixture]::Build($BmpPath,$Bmp2Path,$ReportDir)
$sources = @(
    'rtl/common/async_fifo.v', 'rtl/video/video_timing_gen.v',
    'rtl/storage/framebuf_arbiter.v', 'rtl/storage/sdram_ctrl_wrap.v',
    'rtl/storage/pix_reader.v', 'rtl/storage/fade_mixer.v', 'rtl/storage/fat32_reader.v',
    'rtl/storage/bmp_parser.v', 'rtl/storage/img_loader.v', 'rtl/storage/img_scaler.v', 'rtl/storage/image_player.v',
    'rtl/video/image_window_mask.v',
    'sim/testbench/tb_display_content.v'
)
if ($RealCore) {
    if($CoreReplay) { $sources=@('rtl/storage/sdram_ctrl_wrap.v','sim/testbench/tb_display_content.v') }
    $sources=@('ip/config/sdram/global_def.v','ip/local/sdram/sdr_wrrd.enc.v',
        'ip/local/sdram/sdr_init_ref.enc.v','ip/local/sdram/sdr_as_ram.enc.v',
        'ip/local/sdram/IS42s32200.v')+$sources
}
$hashes = @($sources | ForEach-Object {
    @{path=$_; sha256=(Get-FileHash -LiteralPath (Join-Path $root $_) -Algorithm SHA256).Hash}
})
$result = [ordered]@{
    startedAt=(Get-Date).ToString('o'); status='running'; sources=$hashes;
    bmp=$BmpPath; bmpSha256=(Get-FileHash -LiteralPath $BmpPath -Algorithm SHA256).Hash;
    bmp2=$Bmp2Path; bmp2Sha256=(Get-FileHash -LiteralPath $Bmp2Path -Algorithm SHA256).Hash;
    fixture=$fixtureInfo; byteGap=$ByteGap; reloadCount=$ReloadCount;
    arbiterTurnGap=$ArbiterTurnGap; pixelMHz=25; sdramMHz=40;
    seam='real image_player RTL; modeled external sector service and behavioral SDRAM'
    harnessSha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
}
if($RealCore) {
    $result.seam='production image_player RTL + APUG011 encrypted core + IS42s32200 pin model; modeled external sector service'
    $result.pinModelWordsPerBank=524288
    $result.datasheetTiming=[bool]$DatasheetTiming
}
# ---- A4 分母断言（t9 加）---------------------------------------------------
# 本套件只有一个 case，但"一个 case 都没跑也照样 PASS"的风险与多 case 套件相同：
# vsim 进程若在打印 marker 前被杀，$passed 为 $false 会走 throw，这条已有；
# 真正的缺口是 Sweep 分支（-Sweep）—— sweepCases 为空时
# @(... | Where-Object {...}).Count -eq 0 会判 candidate13Stable=$true，
# 于是"没扫任何一个 gap"被判成通过。两处分母都补上。
$failed = $false
$script:A4Ran    = 0
$script:A4Passed = 0
$ExpCaseCount  = 1   # display 套件主路径只有 tb_display_content 一个 case

$timer=[Diagnostics.Stopwatch]::StartNew()
$previousAmsModelTech=$env:AMS_MODEL_TECH
if($RealCore) { $env:AMS_MODEL_TECH='D:\MentorGraphics\HLVX.2.13\SDD_HOME\hyperlynx64\Ams\pkgs\icx_pro_sim\22.1\libs' }
Push-Location $ReportDir
try {
    & "$ModelSimPath\vlib.exe" work *> vlib.txt
    if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    $compileArgs=@('-quiet','+define+SDRAM_SIM_MODEL')
    if($RealCore) { $compileArgs=@('-mfcu','-permissive','+define+SIMULATION','+define+DISPLAY_REAL_CORE',('+incdir+'+(Join-Path $root 'ip/config/sdram'))) }
    & "$ModelSimPath\vlog.exe" @compileArgs @($sources | ForEach-Object { Join-Path $root $_ }) *> compile.txt
    if ($LASTEXITCODE -ne 0) { throw 'vlog failed; no stale simulation was run' }
    if($SweepReadGaps) {
        $result.seam='two-group APUG011 APP read replay across bank and row transitions'
        $result.sweepCases=@()
        foreach($first in 6..11) {
            foreach($spacing in 4..20) {
                $log='gap{0:D2}_first{1:D2}.txt' -f $spacing,$first
                $argsForCase=@('-c','-quiet','-onfinish','stop',('-gSHORT_GAP='+$spacing),
                    ('-gFIRST_GROUP='+$first),'-gGROUP_COUNT=2',
                    ('-gFUNCTIONAL_TIMING='+$(if($DatasheetTiming){0}else{1})))
                if(-not $DatasheetTiming) { $argsForCase+='+notimingchecks' }
                $argsForCase+=@('-do','onerror {quit -f -code 2}; onbreak {quit -f -code 3}; run -all; quit -f -code 0','work.tb_display_core_replay')
                & "$ModelSimPath\vsim.exe" @argsForCase *> $log
                $exitCode=$LASTEXITCODE
                $transcript=[IO.File]::ReadAllText((Join-Path $ReportDir $log))
                $caseSummary=[regex]::Match($transcript,'SUMMARY: checks=(\d+) errors=(\d+) missing=(\d+) mismatched=(\d+)')
                $config=[regex]::Match($transcript,'CONFIG: SDR_CLK_PERIOD=(\d+) SELF_REFRESH_INTERVAL=(\d+)')
                $casePassed=$exitCode -eq 0 -and $caseSummary.Success -and
                    $caseSummary.Groups[2].Value -eq '0' -and
                    $transcript.Contains('ALL CHECKS PASSED: display_core_replay') -and
                    $transcript -notmatch 'CHECKS FAILED|ERROR:|\*\*\s+(?:Error|Fatal)\b'
                $result.sweepCases+=@{firstGroup=$first;firstAddress=166880+$first*4;
                    gap=$spacing;passed=$casePassed;exitCode=$exitCode;log=$log;
                    errors=$(if($caseSummary.Success){[int]$caseSummary.Groups[2].Value}else{$null});
                    pinErrors=[regex]::Matches($transcript,'ERROR:').Count;
                    refreshInterval=$(if($config.Success){[int]$config.Groups[2].Value}else{$null})}
            }
            $good=@($result.sweepCases | Where-Object {$_.firstGroup -eq $first -and $_.passed} | ForEach-Object gap)
            $bad=@($result.sweepCases | Where-Object {$_.firstGroup -eq $first -and -not $_.passed} | ForEach-Object gap)
            Write-Output ('firstGroup='+$first+' passedGaps='+($good -join ',')+' failedGaps='+($bad -join ','))
        }
        foreach($source in $hashes) {
            if((Get-FileHash -LiteralPath (Join-Path $root $source.path) -Algorithm SHA256).Hash -ne $source.sha256) {
                throw ('Source changed during validation: '+$source.path)
            }
        }
        if (@($result.sweepCases).Count -eq 0) {
            throw 'A4-GATE: sweep 扫到 0 个 gap（分母为 0 时 candidate13Stable 恒真，是假绿）'
        }
        $script:A4Ran = @($result.sweepCases).Count
        $script:A4Passed = @($result.sweepCases | Where-Object {$_.passed}).Count
        $ExpCaseCount = $script:A4Ran   # sweep 的期望数就是它自己扫到的档数（每档必须给出结论）
        Write-Output ('  A4-GATE: sweep ran=' + $script:A4Ran + ' passed=' + $script:A4Passed)
        $result.candidate13Stable=@($result.sweepCases | Where-Object {$_.gap -ge 13 -and -not $_.passed}).Count -eq 0
        $result.status=$(if($result.candidate13Stable){'passed'}else{'failed'})
        Write-Output ('SWEEP: cases='+$result.sweepCases.Count+' candidate13Stable='+$result.candidate13Stable)
        if(-not $result.candidate13Stable) { throw 'At least one spacing >=13 failed; see gap_sweep logs' }
        return
    }
    $simArgs=@('-c','-quiet','-onfinish','stop',"-gRD_GAP=$ByteGap", "-gRELOAD_COUNT=$ReloadCount",
        "-gARBITER_TURN_GAP=$ArbiterTurnGap")
    if($RealCore) {
        $simArgs+='-gFUNCTIONAL_TIMING='+$(if($DatasheetTiming){0}else{1})
        if(-not $DatasheetTiming) { $simArgs+='+notimingchecks' }
    }
    $top='tb_display_content'
    $marker='display_content'
    if($CoreReplay) {
        $top='tb_display_core_replay'; $marker='display_core_replay'
        $simArgs=$simArgs | Where-Object { $_ -notlike '-gRD_GAP=*' }
        $simArgs+="-gSHORT_GAP=$ReplayShortGap"
        $simArgs+="-gFIRST_GROUP=$ReplayFirstGroup"
        $simArgs+="-gGROUP_COUNT=$ReplayGroups"
        $result.seam='APUG011 core APP read-group replay; physical model rows seeded independently'
        $result.replayFirstGroup=$ReplayFirstGroup; $result.replayGroups=$ReplayGroups
        $result.replayShortGap=$ReplayShortGap
    }
    $simArgs+=@('-do','onerror {quit -f -code 2}; onbreak {quit -f -code 3}; run -all; quit -f -code 0',"work.$top")
    & "$ModelSimPath\vsim.exe" @simArgs *> simulation.txt
    $result.exitCode=$LASTEXITCODE
    $content=[IO.File]::ReadAllText((Join-Path $ReportDir 'simulation.txt'))
    $summary=[regex]::Match($content,'SUMMARY: checks=(\d+) errors=(\d+) missing=(\d+) mismatched=(\d+)')
    $passed=$result.exitCode -eq 0 -and $summary.Success -and
        [int]$summary.Groups[1].Value -ge $(if($CoreReplay){$ReplayGroups*4}else{614400}) -and [int]$summary.Groups[2].Value -eq 0 -and
        $content.Contains('ALL CHECKS PASSED: '+$marker) -and
        $content -notmatch 'CHECKS FAILED|(?:^|\n)\s*(?:#\s*)?FAIL\b|\*\*\s+(?:Error|Fatal)\b|ERROR:'
    $script:A4Ran = 1
    $script:A4Passed = $(if ($passed) { 1 } else { 0 })
    $result.pinModelErrors=[regex]::Matches($content,'ERROR:').Count
    if($summary.Success) {
        $result.checks=[int]$summary.Groups[1].Value; $result.errors=[int]$summary.Groups[2].Value
        $result.missing=[int]$summary.Groups[3].Value; $result.mismatched=[int]$summary.Groups[4].Value
    }
    $result.frameIdentical=(Test-Path displayed.ppm) -and (Get-FileHash displayed.ppm).Hash -eq (Get-FileHash expected.ppm).Hash
    if($CoreReplay) { $result.frameIdentical=$null }
    foreach($source in $hashes) {
        if((Get-FileHash -LiteralPath (Join-Path $root $source.path) -Algorithm SHA256).Hash -ne $source.sha256) {
            throw ('Source changed during validation: '+$source.path)
        }
    }
    # ---- A4 分母断言（t9 加）--------------------------------------------
    if ($script:A4Ran -eq 0) {
        Write-Output ('  A4-GATE: ran=0（一个 case 都没跑却要打印通过）')
        $failed = $true
    }
    if ($script:A4Ran -ne $ExpCaseCount) {
        Write-Output ('  A4-GATE: ran=' + $script:A4Ran + ' 与期望 case 数 ' + $ExpCaseCount + ' 不符')
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
    if($failed -or -not $passed -or (-not $CoreReplay -and -not $result.frameIdentical)) { throw 'Display-content regression failed; see simulation.txt' }
    $result.status='passed'
    Write-Output ($summary.Value+' frameIdentical='+$result.frameIdentical)
}
catch { $result.status='failed'; $result.error=$_.Exception.Message; throw }
finally {
    $result.elapsedSeconds=$timer.Elapsed.TotalSeconds
    $result.finishedAt=(Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath result.json -Encoding utf8
    Pop-Location
    $env:AMS_MODEL_TECH=$previousAmsModelTech
}
