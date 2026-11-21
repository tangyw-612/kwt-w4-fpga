param(
    [string]$Port = 'COM7',
    [string]$Vivado = 'E:/VIVADO/Vivado/2020.2/bin/vivado.bat',
    [ValidatePattern('^full(_[a-z0-9]+)*$')]
    [string]$Profile = 'full_keyword_b4_competition_clear_large'
)

$ErrorActionPreference = 'Stop'
$project = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $project
try {
    $candidate = "build/$Profile"
    $fallback = 'build/mac_uart_an970/keyword_acc_mac_uart_an970.bit'
    if (!(Test-Path -LiteralPath "$candidate/keyword_acc_full.bit") -or !(Test-Path -LiteralPath $fallback)) {
        throw '完整识别位流或 AN970 演示位流不存在'
    }

    # 先确认能独占串口，再开始下载。
    python -c 'import sys; sys.path.insert(0,"host"); from mac_uart_protocol import open_board; open_board(sys.argv[1]).close()' $Port
    if ($LASTEXITCODE -ne 0) { throw '部署前串口占用检查未通过' }
    try {
        & $Vivado -mode batch -notrace -log "$candidate/program.log" -journal "$candidate/program.jou" -source scripts/hardware.tcl -tclargs $Profile
        if ($LASTEXITCODE -ne 0) { throw '完整识别位流下载失败' }

        python host/rover_demo.py --mode full --port $Port --verify-all | Tee-Object -FilePath "$candidate/raw_serial.log"
        if ($LASTEXITCODE -ne 0) { throw '十二层末层回读验收失败' }

        python host/keyword_uart_protocol.py --port $Port --verify-replay 0 50 100 150 200 250 300 350 400 450 500 550 599 |
            Tee-Object -FilePath "$candidate/keyword_serial.log"
        if ($LASTEXITCODE -ne 0) { throw '完整识别分类验收失败' }
        'FULL_KEYWORD_DEPLOYED'
    } catch {
        $deploymentFailure = $_
        & $Vivado -mode batch -notrace -log "$candidate/restore_an970.log" -journal "$candidate/restore_an970.jou" -source scripts/hardware.tcl -tclargs mac_uart_an970
        if ($LASTEXITCODE -ne 0) { throw "完整部署失败，且 AN970 演示恢复失败。原始错误 $deploymentFailure" }
        $results = python host/mac_uart_protocol.py --port $Port 250 100 | Tee-Object -FilePath "$candidate/restored_an970_serial.log"
        if ($LASTEXITCODE -ne 0) { throw "完整部署失败，且 AN970 恢复后串口验收失败。原始错误 $deploymentFailure" }
        $rows = @($results | Where-Object { $_ -like '{*' } | ConvertFrom-Json)
        if ($rows.Count -ne 2 -or ($rows | Where-Object { $_.status -ne 0 -or $_.matches -ne 2 })) {
            throw "完整部署失败，且 AN970 恢复后点积验收失败。原始错误 $deploymentFailure"
        }
        $results
        throw $deploymentFailure
    }
} finally {
    Pop-Location
}
