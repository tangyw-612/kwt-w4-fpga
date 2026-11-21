# AXU2CG-E 语音小车上板工程

目标器件 `xczu2cg-sfvc784-1-e`，使用 Vivado 2020.2。PL 计算、串口和 800×480 扫描共用 33.333 MHz 时钟。图形由像素坐标和小字模直接生成。

## 完整 W4 板载演示

比赛使用已通过实板彩排的清晰大字版。上电、JTAG 下载、评委抽样和故障恢复见[比赛现场操作清单](比赛现场操作清单.md)。

`full_keyword_b4_competition_clear_large` 集成双项 MAC、12 层编码器、12 类定点分类头和 AN970 竞赛界面。编号 000–599 的录音特征和模型参数由 PC 经 J8 送入，FPGA 返回预测类别。AN970 根据评测清单中的真实标签显示一致性、表情和实测编码层数。底图仍以 400×240 存储，标志和静态文字按 800×480 屏幕像素叠加。共享图块后的整板布局使用 149/150 块 BRAM。250、100、200、400 的末层均通过 6,336 字比对，记录在 `build/full_keyword_b4_competition_clear_large/`。

在上位机页面点击「连接 J8」，选择样本运行。示例为 250 向右、100 向上、200 向左、400 停止。断电后在本工程目录执行以下命令，可重新通过 JTAG 下载完整位流并复验。

```powershell
& ./scripts/deploy_full_keyword.ps1 -Port COM7 -Profile full_keyword_b4_competition_clear_large
```

复验界面可运行 104（UP，一致）和 408（UNKNOWN，真实标签 STOP，不一致）。重建背景和字模使用 `python host/make_an970_competition.py`，随后用 `scripts/link_full.tcl` 的 `live` 模式链接 W4 检查点。上一版清晰界面可用 `full_keyword_b4_competition_clear` 通过 JTAG 重新加载。

## 连接和操作

1. 关闭开发板电源，将 AN970 的 P4 接到板上 **J45**，对齐 Pin 1 和缺口。面板由 J45 供电。
2. 从冷启动走 JTAG 时将 **SW1 的 1、2、3、4 位全部设为 ON**。连接 JTAG，打开 12 V 电源。
3. 初次接屏可下载彩条确认显示。MAC 保底演示用 **PL KEY** 依次执行 RIGHT、UP、LEFT、STOP，屏幕显示两个计算结果。完整版从上位机选择样本。
4. 电脑控制用 **J8** 的 PL UART，`921600 8N1`。本机装好 CP210x 驱动后对应 `COM7`，四条保底指令的实板串口回执均通过。

保底版已在 `xczu2` 实板通过四条指令的 JTAG 检查，32 次双项归约和写出合计 41 拍，两个点积与参考一致，小车车位正确。扫描端实测 384,000 个有效像素每帧。布局布线报告为 2,117 LUT、1 块 BRAM、0 个 DSP，建立裕量 +4.910 ns，保持裕量 +0.011 ns。位流在 `build/mac/keyword_acc_mac.bit`，实板记录在 `build/vivado_program_mac.log`。

## 构建与下载

在本目录启动 PowerShell。只重建 `build` 中相应模式的工程。

```powershell
$vivado = 'E:/VIVADO/Vivado/2020.2/bin/vivado.bat'
New-Item -ItemType Directory -Path build -Force | Out-Null
python host/make_mac_vectors.py
& $vivado -mode batch -source scripts/build.tcl -tclargs bars bit
& $vivado -mode batch -source scripts/build.tcl -tclargs mac bit
& $vivado -mode batch -source scripts/hardware.tcl -tclargs mac test
```

`bars` 测试 J45 屏幕时序，`bars_steady` 提供恒亮背光的排查位流。`mac` 保留冻结设计的 W4 双项归约和 44 位累加，针对四条样本的两个 Q 投影输出实际执行 32 次双项归约。通过标志来自两个输出与独立整数参考的逐字比较。`mac test` 通过 JTAG VIO 核对四条指令的结果、周期、车位以及每帧有效像素数。下载写入 FPGA 配置 SRAM。

```powershell
& scripts/sim_board.ps1
python -m pip install --target build/pydeps -r host/requirements.txt
python host/rover_demo.py --check-assets
python host/rover_demo.py --mode mac --port COM7
```

可加 `--sample UP` 在终端跑一条，或者加 `--verify-all` 依次验收四条。MAC 保底中，电脑选择的录音决定测试向量和小车指令，板端点积通过后执行动作。

现场可依次播放 RIGHT、UP、LEFT、STOP。前三条在 AN970 上显示行驶轨迹，STOP 让车位保持在最后一格。屏幕同时显示两个 W4 点积和 `MATCH 2/2`。下载完成并保持开发板供电后，拔掉 J8 也可用 PL KEY 演示。开发板断电后需重新通过 JTAG 下载。

## J8 编号联调

`mac_uart` 位流在同一 W4 点积通路上增加编号帧。上位机下发两字节样本编号，板端回传编号、事务号、两个有符号点积、计算周期和通过数。支持 `100`、`200`、`250`、`400` 的计算，其余 `000–599` 编号返回无向量。J8 使用 `921600 8N1`，遍历或抽样仍保留在离线回放模式。

```powershell
& scripts/sim_board.ps1 -FramedUart
& $vivado -mode batch -source scripts/build.tcl -tclargs mac_uart bit
& $vivado -mode batch -source scripts/hardware.tcl -tclargs mac_uart
python host/mac_uart_protocol.py --port COM7 100 200 250 400 599
python ../../presentations/kwt_host_gui/board_server.py --port COM7
```

打开网关打印的本地地址，在「板端监测」点「连接 J8」。切回离线后可以继续播放原来的 600 条评测样本。便携包直接打开时使用离线回放。

`mac_uart_an970` 位流使用新版 AN970 界面。屏幕显示 J8 样本编号和对应的真实录音波形，点积校验栏在收到四条板载样本的结果后显示真实点积和周期。其他编号仍可显示样本波形。数据、标志和固定标题使用小型 ROM，画面按像素扫描生成。

```powershell
python host/make_an970_assets.py
& scripts/sim_board.ps1 -LinkScreen
& $vivado -mode batch -source scripts/build.tcl -tclargs mac_uart_an970 bit
& $vivado -mode batch -source scripts/hardware.tcl -tclargs mac_uart_an970
```

## 12 层编码器原型

`full/` 保留 32 通道双行编码结构和每层的原始定点运算，在 FPGA 版替换 ASIC SRAM，并优化乘法器映射。暂用 PC 串口流送数据，从原有四条样本复用输入和参考。每任务送入约 401 kB，板端逐块许可发送并保留核端反压，最终吐回 6,336 个 32 位字。串口适配器已做独立的协议仿真，包括反压、尾块和复位重试。

`split_bram_pv_signed` 源码重建版使用 41,735/47,232 LUT、146.5/150 块等效 BRAM36 和 194/240 个 DSP，建立裕量 +4.548 ns，保持裕量 +0.015 ns。五个 RTL 样本的全 12 层通过逐字比对。四条 COM7 实板任务均完成 12 层，扣除等参均为 965,557 拍，末层数值验收均为 0/6,336。四个样本返回的末层向量相同。现场使用已验收的 MAC 位流。

源码重建版的四条实板日志及末层回读位于 `build/full_release`。基于同一修订乘加核的快速网表替换版也做了实板校验，结果位于 `build/full_signed`，其回读与源码重建版逐字相同。早期版本的末层回读位于 `build/board_results` 和 `build/board_readback`。

串口隔离验收复用板级外壳。四个样本各发送 400,696 字节，整包 CRC32 和前 6,335 个回读字全部一致。记录位于 `build/diag_transport/transport_physical.log`。独立激活缓冲的 Vivado 功能网表也通过 6,336 地址读写检查。

对 `sample_250` 跑整核功能网表时，初始 6,336 个激活字的写地址和写数据全部通过。实板 ILA 抽查同一输入的 192 个写字均正确，首层写回的首行 64 个字全部偏离参考，地址 0 的实际值 `fff745d5` 与门级仿真相同，参考为 `ffda1f91`。抓取记录位于 `build/diag_ila`。从同一网表抽出的 32 通道乘加阵列可单独复现偏差，记录见 `full/build/mac_gate/mac_gate.log`。

全核的预处理、仿真和资源评估在 `full/`。修订的 `split_bram_pv_signed` 显式保留 DSP 乘法、通道缩放和 44 位累加的符号，单阵列门级比对通过 384 个结果，五个完整样本的 RTL 逐字比对通过。下面的命令从源码综合修订版，再链接板级外壳。第三行可选，用于生成可在 Vivado 直接打开的源码工程。

```powershell
& full/scripts/assess.ps1 -MacMap split_bram_pv_signed
& $vivado -mode batch -source scripts/link_full.tcl -tclargs full/build/ooc_split_bram_pv_signed/w4_full_stream.dcp full_release
& $vivado -mode batch -source scripts/build.tcl -tclargs full project
```

整核实板验收使用 `python host/rover_demo.py --mode full --port COM7 --verify-all`。上位机逐字校验末层回读，通过后从 FPGA 返回的 CLS 计算分类。分类头权重、偏置和类别顺序来自原提交包。核内周期从查找表装载后启动到末层编码完成，包含各层的参数等待。

### 首层激活和 K 投影抓取

`full_first_k` 在重现末层偏差的同一全核检查点上加 ILA。以首次双行双列激活读取为第 0 拍，取第二行的奇偶列 RAM 输出与 `g_mac[1].u_mac/out_data`，用原始输入文件和 RTL 逐拍对照。两条实板任务均复现了原末层回读的 SHA-256。

| 样本 | 第二行激活读出 | 第二行 K 投影 | 第 43 拍第 0 列实板 | RTL |
| --- | ---: | ---: | --- | --- |
| 250 | 64/64 | 0/64 | `059b32a8` | `ffe267d1` |
| 100 | 64/64 | 0/64 | `059a05fa` | `ffe0b908` |

首次差异落在首组 K 输出。两条样本的首个 K 输出仍彼此不同，末层回读完全相同。K 的参考值也使用归档 W4 权重、输入和尺度做了独立整数复算。对实际布线的 MAC 功能网表送入参考权重和尺度，输出与奇项 DSP 符号丢失模型一致，但与实板这两条样本的 128 个 K 值均不同。诊断范围已缩小到激活 RAM 输出之后的 K 运算路径，涉及输入选择、权重读取、乘加和通道缩放。原始波形、逐项结果和恢复新版 AN970 的记录位于 `build/full_first_k`，MAC 功能网表对照位于其中的 `mac_gate/observed.log`。

```powershell
& full/scripts/simulate_fast.ps1 -MacMap split_bram_pv_signed -Samples sample_250,sample_100 -FirstKTrace
& $vivado -mode batch -source scripts/link_full.tcl -tclargs full/build/ooc_split_bram_pv_signed/w4_full_stream.dcp full_first_k first_k
& scripts/run_first_k_capture.ps1 -Port COM7
python host/first_k_trace.py compare build/full_first_k full/build/vlt_split_bram_pv_signed_first_k
```

### 第 0 层第二行第 0 个 K 通道的 MAC 对照

复用 `full_first_k` 已布线的 ILA 分两次抓取。第一版取 MAC 入口两路激活和两颗低位乘法 DSP 的 18 位 B 端，第二版取 44 位累加器、写出锁存值和 12 位通道缩放系数。两版的读取触发和末层回读 SHA-256 均与原故障一致。对照表位于 `build/full_first_k_accum_eco/mac_comparison.csv`，原始波形分存于 `build/full_first_k_operands_eco` 和 `build/full_first_k_accum_eco`。

两条样本的激活奇偶端各 32/32 正确。首个错误在第 2 拍，两个 DSP 的首项权重都从应有的 `3fffc`（−4）变成了 `0000c`（+12）。两颗 DSP 的 64 个权重值都等于 RTL 权重的低四位，原有符号扩展丢失。第 4 拍首次累加出错。用实测激活和 DSP 权重复算，两个样本的 32 次累加各自全部匹配实板。

| 样本 | 第 35 拍最终 44 位和 · RTL | 第 35 拍最终 44 位和 · 实板 | 第 39 拍尺度 · 两端相同 |
| --- | --- | --- | ---: |
| 250 | `ffff97c53cd` | `0013bea928d` | 1163 |
| 100 | `ffff91d80ca` | `0013ba8631a` | 1163 |

第 39 拍写出锁存值与各自第 35 拍的实板最终和一致。用这两个值乘以 1163，按原量化规则右移 16 位，逐字复现此前第 43 拍的 K 错值 `059b32a8` 和 `059a05fa`。抓取后已恢复 `mac_uart_an970`，并在 COM7 上复测编号 250、100 的双点积均通过。

板卡引脚依据 ALINX 的 AXU2CG-E 手册和 [lcd7 官方例程](https://github.com/alinxalinx/AXU2CG-E_AXU3EG_AXU4EV-E_AXU5EV-E/tree/master/demo/course_s1/13_1_lcd7_project)。
