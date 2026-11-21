param(
    [string]$Port = 'COM7',
    [string]$Vivado = 'E:/VIVADO/Vivado/2020.2/bin/vivado.bat',
    [ValidateSet('full_first_k', 'full_first_k_operands', 'full_first_k_accum', 'full_first_k_operands_eco', 'full_first_k_accum_eco')]
    [string[]]$Profiles = @('full_first_k')
)

$ErrorActionPreference = 'Stop'
$project = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$python = (Get-Command python.exe).Source
Push-Location $project
try {
    foreach ($variant in $Profiles) {
        $debugBuild = "build/$variant"
        if (!(Test-Path -LiteralPath "$debugBuild/keyword_acc_full.bit") -or
            !(Test-Path -LiteralPath "$debugBuild/keyword_acc_full.ltx")) {
            throw "首层 K 调试位流或探针文件不存在：$variant"
        }
    }
    $restoreBuild = "build/$($Profiles[-1])"
    try {
        foreach ($variant in $Profiles) {
            $debugBuild = "build/$variant"
            & $Vivado -mode batch -notrace -log "$debugBuild/capture.log" -journal "$debugBuild/capture.jou" -source scripts/capture_first_k.tcl -tclargs $variant $python $Port
            if ($LASTEXITCODE -ne 0) { throw "首层 K 实板抓取失败：$variant" }
        }
    } finally {
        & $Vivado -mode batch -notrace -log "$restoreBuild/restore_an970.log" -journal "$restoreBuild/restore_an970.jou" -source scripts/hardware.tcl -tclargs mac_uart_an970
        if ($LASTEXITCODE -ne 0) { throw '新版 AN970 位流恢复失败' }
        $checks = & $python host/mac_uart_protocol.py --port $Port 250 100 | Tee-Object -FilePath "$restoreBuild/restored_an970_serial.log"
        if ($LASTEXITCODE -ne 0) { throw '新版 AN970 恢复后串口验收失败' }
        $results = @($checks | Where-Object { $_ -like '{*' } | ConvertFrom-Json)
        if ($results.Count -ne 2 -or ($results | Where-Object { $_.status -ne 0 -or $_.matches -ne 2 })) {
            throw '新版 AN970 恢复后点积未通过逐字验收'
        }
        $checks
    }
} finally {
    Pop-Location
}
