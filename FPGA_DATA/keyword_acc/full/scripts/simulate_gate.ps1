param(
    [string]$VivadoBin = 'E:/VIVADO/Vivado/2020.2/bin',
    [string]$Checkpoint,
    [ValidatePattern('^sample_[0-9]{3}$')]
    [string]$Sample = 'sample_250'
)

$ErrorActionPreference = 'Stop'
$full = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$project = (Resolve-Path (Join-Path $full '../../..')).Path
$vectors = (Join-Path $project 'research/kwt12042_handoff_20261119/server/w4_hundred_lean_mac/vectors').Replace('\', '/')
if (!$Checkpoint) { $Checkpoint = Join-Path $full 'build/ooc_split_bram_pv_signed/w4_full_stream.dcp' }
$Checkpoint = (Resolve-Path $Checkpoint).Path
$profile = (Split-Path -Leaf (Split-Path -Parent $Checkpoint)) -replace '^ooc_', ''
$sim = Join-Path $full "build/gate_$profile"
New-Item -ItemType Directory -Path $sim -Force | Out-Null
Push-Location $sim
try {
    & "$VivadoBin/vivado.bat" -mode batch -source "$PSScriptRoot/export_encoder_gate.tcl" -tclargs $Checkpoint $sim
    if ($LASTEXITCODE -ne 0) { throw '功能网表导出失败' }
    & "$VivadoBin/xvlog.bat" --sv -d W4_GATE_FIRST_LAYER encoder_gate.v "$full/sim/tb_full_stream.sv" *> compile.log
    if ($LASTEXITCODE -ne 0) { throw "功能网表编译失败 $sim/compile.log" }
    # 保留 glbl 的皮秒单位，全局复位应在 100 纳秒结束。
    & "$VivadoBin/xelab.bat" tb_full_stream glbl -s encoder_gate -mt 2 -L unisims_ver -L unimacro_ver *> elaborate.log
    if ($LASTEXITCODE -ne 0) { throw "功能网表展开失败 $sim/elaborate.log" }
    $progress = (Join-Path $PSScriptRoot 'gate_progress.tcl').Replace('\', '/')
    @('encoder_gate', "--tclbatch `"$progress`"", "--testplusarg `"vectors=$vectors`"",
      "--testplusarg `"sample=$Sample`"", "--log $Sample.log") |
        Set-Content -LiteralPath "$Sample.args" -Encoding ascii
    & "$VivadoBin/xsim.bat" -f "$Sample.args"
    if ($LASTEXITCODE -ne 0 -or !(Select-String -Path "$Sample.log" -Pattern '^W4_GATE_FIRST_LAYER_PASS ' -Quiet)) {
        throw "首层功能网表校验失败 $sim/$Sample.log"
    }
} finally {
    Pop-Location
}
