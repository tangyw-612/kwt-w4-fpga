# KWT-STAR · W4 关键词识别 FPGA 工程

开发板为 ALINX AXU2CG-E，显示屏为 AN970。比赛最终大字版在 FPGA 上运行 W4 十二层编码器和分类头，上位机经 J8 串口下发特征与参数，并显示板端回传的分类结果。

ASIC RTL、E203 NICE 接口和工艺适配见 [W4 ASIC](asic/w4/README.md)。

## 使用比赛位流

在仓库根目录打开 PowerShell。AN970 接 J45，PL UART 接 J8，JTAG 下载器接电脑。下列命令中的 Vivado 安装路径和串口号按本机修改。

```powershell
$vivado = 'E:/VIVADO/Vivado/2020.2/bin/vivado.bat'
Push-Location FPGA_DATA/keyword_acc
& $vivado -mode batch -notrace -source scripts/hardware.tcl -tclargs full_keyword_b4_competition_clear_large
Pop-Location
python -m pip install -r FPGA_DATA/keyword_acc/host/requirements.txt
python presentations/kwt_host_gui/board_server.py --port COM7 --listen 8771
```

在浏览器打开 `http://127.0.0.1:8771/presentations/kwt_host_gui/?board=1`，连接 J8，选择 000–599 中的一条样本。完整接线、启动开关和回退方式见[比赛现场操作清单](FPGA_DATA/keyword_acc/比赛现场操作清单.md)。清单中的 D 盘工程路径替换为本仓库的克隆位置。

## 从源码构建

使用 Vivado 2020.2 和支持 Zynq UltraScale+ 的器件库。以下命令先综合 W4 编码核，再与串口、分类头及 AN970 显示逻辑一起布局布线，输出到独立目录。

```powershell
$vivado = 'E:/VIVADO/Vivado/2020.2/bin/vivado.bat'
Push-Location FPGA_DATA/keyword_acc
& ./full/scripts/assess.ps1 -Vivado $vivado -MacMap split_bram_pv_signed_b4_gelu
& $vivado -mode batch -notrace -source scripts/link_full.tcl -tclargs full/build/ooc_split_bram_pv_signed_b4_gelu/w4_full_stream.dcp full_rebuild live
Pop-Location
```

## 验证记录

- [比赛最终位流](FPGA_DATA/keyword_acc/build/full_keyword_b4_competition_clear_large/keyword_acc_full.bit) 的 SHA-256 为 `4ca3bb35404b6544d634faf12ab18dd2f04102a3a8f8e10429f9b353b8ed2f62`。[大字版实板彩排](FPGA_DATA/keyword_acc/build/full_keyword_b4_competition_clear_large/rehearsal_20261120_012048/rehearsal.json)
- 较早的 W4 位流完成 600 次板上测试，全部预测与离线参考一致，585 次与真实标签一致。[回归汇总](FPGA_DATA/keyword_acc/build/full_keyword_b4_gelu/board600_20261119_223158/summary.json)
- [Vivado 布线后功耗估算与测试条件](FPGA_DATA/keyword_acc/答辩功耗估算表.md)
