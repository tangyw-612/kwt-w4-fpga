param(
    [string]$CompilerBin = 'D:/mingw64/bin',
    [string]$MsysBin = 'C:/msys64/usr/bin',
    [ValidatePattern('^sample_[0-9]{3}$')]
    [string[]]$Samples = @('sample_000'),
    [ValidateSet('lut', 'split', 'split_bram', 'split_bram_pv', 'split_bram_pv_signed', 'split_bram_pv_signed_b16', 'split_bram_pv_signed_b4', 'split_bram_pv_signed_b4_gelu')]
    [string]$MacMap = 'split_bram',
    [switch]$Paced,
    [switch]$SynthesisDefine,
    [switch]$FirstKTrace,
    [switch]$FirstKMacTrace,
    [switch]$FirstLayerMacTrace
)

$ErrorActionPreference = 'Stop'
$fullRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$projectRoot = (Resolve-Path (Join-Path $fullRoot '../../..')).Path
$archive = (Join-Path $projectRoot 'research/kwt12042_handoff_20261119/server/w4_hundred_lean_mac').Replace('\', '/')
$sourceDir = if ($MacMap -eq 'lut') { 'generated' } else { "generated_$MacMap" }
$profileSuffix = $(if ($Paced) { '_paced' }) + $(if ($SynthesisDefine) { '_synth' }) + $(if ($FirstKTrace) { '_first_k' }) + $(if ($FirstKMacTrace) { '_first_k_mac' }) + $(if ($FirstLayerMacTrace) { '_first_layer_mac' })
$simDir = Join-Path $fullRoot "build/vlt_$MacMap$profileSuffix"
$defines = @(if ($SynthesisDefine) { '-DSYNTHESIS' })
$traceSources = @(
    if ($FirstKTrace) { "$fullRoot/sim/trace_first_k.sv" }
    if ($FirstKMacTrace) { "$fullRoot/sim/trace_first_k_mac.sv" }
    if ($FirstLayerMacTrace) { "$fullRoot/sim/trace_first_layer_mac.sv" }
)
$pattern = @(if ($Paced) { '+paced' })

python (Join-Path $PSScriptRoot 'prepare.py') --mac-map $MacMap
if ($LASTEXITCODE -ne 0) { throw '生成仿真清单失败' }
New-Item -ItemType Directory -Path $simDir -Force | Out-Null
$savedPath = $env:PATH
Push-Location $simDir
try {
    & verilator --cc --exe --main --timing --assert -Wno-fatal @defines -f "$fullRoot/build/$sourceDir/sources.f" --top-module tb_full_stream "$fullRoot/sim/tb_full_stream.sv" "$archive/check_pair_layers.sv" @traceSources *> compile.log
    if ($LASTEXITCODE -ne 0) { throw "Verilator 生成失败 $simDir/compile.log" }

    # 单独编译对象，避开 Windows 下归档命令的参数拼接差异。
    'all_objects: $(VK_OBJS) $(VK_GLOBAL_OBJS) $(VK_USER_OBJS)' |
        Set-Content -LiteralPath 'obj_dir/compile_objects.mk' -Encoding ascii
    $env:PATH = "$CompilerBin;$MsysBin;$savedPath"
    & make -C obj_dir -f Vtb_full_stream.mk -f compile_objects.mk all_objects -j1 "CXX=$CompilerBin/g++.exe" CXXFLAGS=-std=c++20 CFG_CXXFLAGS_PCH_I=-include "SHELL=$MsysBin/sh.exe" *> make.log
    if ($LASTEXITCODE -ne 0) { throw "仿真对象编译失败 $simDir/make.log" }
    $objects = (Get-ChildItem -LiteralPath 'obj_dir' -Filter '*.o').FullName
    & "$CompilerBin/g++.exe" -std=c++20 @objects -o 'obj_dir/Vtb_full_stream.exe' -pthread -latomic
    if ($LASTEXITCODE -ne 0) { throw '仿真链接失败' }

    foreach ($sample in $Samples) {
        $log = "$sample.log"
        & 'obj_dir/Vtb_full_stream.exe' "+vectors=$archive/vectors" "+sample=$sample" @pattern |
            Tee-Object -FilePath $log | Where-Object { $_ -notmatch '^(KTRACE|KMTRACE|STAGEMAC|GELUTRACE|F2IN) ' }
        if ($LASTEXITCODE -ne 0) { throw "仿真失败 $sample" }
        if (!(Select-String -Path $log -Pattern "W4_FULL_STREAM_PASS sample=$sample layers=12 words=6336" -Quiet)) {
            throw "未取得完整逐字比对证据 $sample"
        }
        $layers = @(Select-String -Path $log -Pattern '^PAIR_LAYER_PASS ').Count
        if ($layers -ne 12) { throw "逐层比对记录数错误 $sample" }
    }
} finally {
    $env:PATH = $savedPath
    Pop-Location
}
