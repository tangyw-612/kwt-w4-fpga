param([string]$VivadoBin = 'E:/VIVADO/Vivado/2020.2/bin', [switch]$FramedUart, [switch]$LinkScreen)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$protocol = $FramedUart -or $LinkScreen
$bench = if ($LinkScreen) { 'tb_an970_link' } elseif ($FramedUart) { 'tb_mac_uart' } else { 'tb_mac_board' }
$pass = if ($protocol) { 'J8_RTL_PASS' } else { 'MAC_AN970_RTL_PASS' }
$work = Join-Path $root $(if ($LinkScreen) { 'build/sim_an970_link' } elseif ($FramedUart) { 'build/sim_mac_uart' } else { 'build/sim_board' })
New-Item -Type Directory -Path $work -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'data/mac_vectors.mem'),(Join-Path $root 'data/mac_expected.mem') -Destination $work
$modules = @('board_key', 'uart_byte', 'w4_projection_pair', 'w4_mac_demo', 'mac_demo_control', 'keyword_acc_top',
             'rover_scene', 'rover_motion', 'lcd_font', 'an970_raster')
$sources = @($modules | ForEach-Object { Join-Path $root "rtl/$_.sv" })
$sources += (Join-Path $root 'sim/tb_mac_board.sv')
if ($protocol) {
    $sources += (Join-Path $root 'rtl/mac_uart_frame.sv'), (Join-Path $root 'sim/tb_mac_uart.sv')
}
if ($LinkScreen) {
    $sources += (Join-Path $root 'rtl/an970_link_art.sv'), (Join-Path $root 'rtl/an970_link_scene.sv')
    foreach ($name in @('an970_logo.mem','an970_palette.mem','an970_labels.mem','an970_waves.mem')) {
        Copy-Item -LiteralPath (Join-Path $root "data/$name") -Destination $work
    }
}

Push-Location -LiteralPath $work
try {
    & (Join-Path $VivadoBin 'xvlog.bat') --sv @sources
    if ($LASTEXITCODE -ne 0) { throw 'RTL 编译失败' }
    & (Join-Path $VivadoBin 'xelab.bat') --timescale 1ns/1ps $bench -s mac_board_sim
    if ($LASTEXITCODE -ne 0) { throw '测试平台展开失败' }
    & (Join-Path $VivadoBin 'xsim.bat') mac_board_sim -runall
    if ($LASTEXITCODE -ne 0) { throw '板级仿真失败' }
    if (!(Select-String -LiteralPath 'xsim.log' -Pattern $pass -Quiet)) { throw '未找到仿真通过标记' }
} finally { Pop-Location }
