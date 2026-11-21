param(
    [string]$VivadoBin = 'E:/VIVADO/Vivado/2020.2/bin',
    [ValidatePattern('^sample_[0-9]{3}$')]
    [string[]]$Samples = @('sample_000'),
    [ValidateSet('lut', 'split', 'split_bram', 'split_bram_pv', 'split_bram_pv_signed', 'split_bram_pv_signed_b4', 'split_bram_pv_signed_b4_gelu')]
    [string]$MacMap = 'lut'
)

$ErrorActionPreference = 'Stop'
$fullRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$projectRoot = (Resolve-Path (Join-Path $fullRoot '../../..')).Path
$archive = (Join-Path $projectRoot 'research/kwt12042_handoff_20261119/server/w4_hundred_lean_mac').Replace('\', '/')
$sourceDir = if ($MacMap -eq 'lut') { 'generated' } else { "generated_$MacMap" }
$simDir = Join-Path $fullRoot $(if ($MacMap -eq 'lut') { 'build/xsim' } else { "build/xsim_$MacMap" })

python (Join-Path $PSScriptRoot 'prepare.py') --mac-map $MacMap
if ($LASTEXITCODE -ne 0) { throw '生成仿真清单失败' }
New-Item -ItemType Directory -Path $simDir -Force | Out-Null
Push-Location $simDir
try {
    & "$VivadoBin/xvlog.bat" --sv --incr -f "$fullRoot/build/$sourceDir/sources.f" "$fullRoot/sim/tb_full_stream.sv" "$archive/check_pair_layers.sv"
    if ($LASTEXITCODE -ne 0) { throw '仿真编译失败' }
    & "$VivadoBin/xelab.bat" tb_full_stream -s full_tb -mt 4 --timescale 1ns/1ps --override_timeunit
    if ($LASTEXITCODE -ne 0) { throw '仿真展开失败' }
    foreach ($sample in $Samples) {
        $arguments = "run_$sample.args"
        $log = "$sample.log"
        @('full_tb', '--runall', "--testplusarg `"vectors=$archive/vectors`"",
          "--testplusarg `"sample=$sample`"", "--log $log") |
            Set-Content -LiteralPath $arguments -Encoding ascii
        & "$VivadoBin/xsim.bat" -f $arguments
        if ($LASTEXITCODE -ne 0) { throw "仿真失败 $sample" }
        if (!(Select-String -Path $log -Pattern "W4_FULL_STREAM_PASS sample=$sample layers=12 words=6336" -Quiet)) {
            throw "未取得完整逐字比对证据 $sample"
        }
        $layers = @(Select-String -Path $log -Pattern '^PAIR_LAYER_PASS ').Count
        if ($layers -ne 12) { throw "逐层比对记录数错误 $sample" }
    }
} finally {
    Pop-Location
}
