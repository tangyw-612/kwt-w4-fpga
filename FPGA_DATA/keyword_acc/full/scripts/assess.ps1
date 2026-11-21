param(
    [string]$Vivado = 'E:/VIVADO/Vivado/2020.2/bin/vivado.bat',
    [ValidateSet('lut', 'split', 'split_bram', 'split_bram_pv', 'split_bram_pv_signed', 'split_bram_pv_signed_b16', 'split_bram_pv_signed_b4', 'split_bram_pv_signed_b4_gelu')]
    [string]$MacMap = 'lut'
)

$ErrorActionPreference = 'Stop'
$fullRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
python (Join-Path $PSScriptRoot 'prepare.py') --mac-map $MacMap
if ($LASTEXITCODE -ne 0) { throw '生成综合清单失败' }
Push-Location (Join-Path $fullRoot 'build')
try {
    & $Vivado -mode batch -notrace -source "$PSScriptRoot/ooc.tcl" -log "ooc_$MacMap.log" -journal "ooc_$MacMap.jou" -tclargs $MacMap
    if ($LASTEXITCODE -ne 0) { throw 'Vivado 资源评估失败' }
} finally {
    Pop-Location
}
