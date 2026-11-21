# W4 十二层流接口原型

目标器件为 `xczu2cg-sfvc784-1-e`，时钟约 33.333 MHz。Vivado 2020.2 重新综合原 W4 的 32 路双行编码器。主机通过同一流接口送输入和参数，编码器的层间激活、单端口时序与下一层权重预取在 FPGA 内。

## 构建和数值检验

从项目根目录运行。

```powershell
& .\FPGA_DATA\keyword_acc\full\scripts\simulate.ps1 -MacMap split_bram_pv_signed -Samples sample_000
& .\FPGA_DATA\keyword_acc\full\scripts\assess.ps1 -MacMap split_bram_pv_signed
```

`simulate.ps1` 逐层比对 LN2 的 76,032 个输出字，再从回读接口比对末层 6,336 个字。默认从本仓库的 W4 归档取向量和 RTL，准备步骤生成适配副本。配有 Verilator 和支持 C++20 的 MinGW 时，可用 `simulate_fast.ps1` 执行相同检查。独立综合报告保存在 `build/ooc_<映射名称>`。

## 已验证的数值结果

`split_bram` 和 `split` 映射在 Verilator 下均通过 `sample_000`、`sample_100`、`sample_200`、`sample_250` 和 `sample_400` 的 12 层逐位对照。每个样本均核对 76,032 个逐层输出字和 6,336 个末层回读字。仿真核内耗时 980,155 拍，其中等参数 14,598 拍。仿真以理想流驱动，串口传输另计。日志位于 `build/vlt_split_bram` 和 `build/vlt_split`。

`lut` 映射的 `sample_000` 在 Vivado XSIM 2020.2 的四态仿真通过同一组对照。日志位于 `build/xsim/sample_000.log`。

## 全核装载契约

空闲时拉高 `start` 一拍。随后通过 `in_valid/in_ready` 发送以下小端 32 位字。等待 `in_ready` 时保持当前字和 `in_valid`。

| 顺序 | 文件 | 字数 |
| --- | --- | ---: |
| 1 | `loader/<sample>/input.bin` | 6,336 |
| 2 | `loader/gelu.bin` | 4,097 |
| 3 | `loader/exp.bin` | 4,097 |
| 4 | `loader/parameters/layer_00.bin` 至 `layer_11.bin` | 12 × 7,137 |

总长 400,696 字节。使用主机流供数时，板端对参数节拍施加反压，可通过分包确认让主机安全暂停。输出通过 `out_valid/out_ready` 回读 6,336 个字；最后一个词被接收后 `done` 拉高一拍。没有异步跨域需求时可与板端控制面共用一个时钟。

`layers_completed` 来自编码器的逐层完成脉冲。`cycles` 从输入和两个查找表装载完毕起计，到十二层计算结束为止，包含等候层参数的 `wait_cycles`。串口传输和结果回读应另计。

## 资源适配

- 主机流代替 E203 与 512 KiB 共享 SRAM。权重文件常驻 PC，若日后连接 PS DDR，可复用同一流入口。
- FPGA 存储沿用原 SRAM 的同步读出和停用保持。LayerNorm 的 γ/β 分片写入保留十六位掩码。
- `lut` 将两个奇项上半部乘法转向 LUT。`split` 将偶项拆成一个 27×17 DSP 乘法与一个 6×4 LUT 乘法，将 16×4 奇项高位放入 LUT，并保留 P×V 的奇项高位 DSP。推理仿真同时检查实际输入满足拆分位宽约束。
- `split_bram` 将 204 个 128×16 存储切片改为同步块存储，保留 `split` 的功能节拍和数值对照结果。

| Vivado 2020.2 全核独立综合 | LUT | 等效 BRAM36 | DSP |
| --- | ---: | ---: | ---: |
| 器件资源 | 47,232 | 150 | 240 |
| `split` | 50,370 | 44 | 240 |
| `split_bram` | 43,643 | 146 | 240 |
| `split_bram_pv` | 41,616 | 146 | 194 |
| `split_bram_pv_signed` | 42,453 | 146 | 194 |

`split_bram` 比 `split` 节约 6,727 个 LUT。`split_bram_pv` 又节约 2,027 个 LUT 和 46 个 DSP，给板端外壳留出 5,616 个 LUT、4 块等效 BRAM36 和 46 个 DSP。以上为编码器独立综合资源，板端可用性以集成后的布局布线及实板回读为准。

`split_bram` 输出可链接的 `build/ooc_split_bram/w4_full_stream.dcp`。30 ns 周期下的综合后估计 WNS 为 +10.930 ns，WHS 为 +0.046 ns。该估计未计入布局布线后的时钟偏差。

## 实板诊断和 PV 乘法适配

早期 `split_bram` 板级构建完成 12 层并回读全部 6,336 字。`sample_250` 的末层比对为 0/6,336，实际首字为 1,597,801，参考为 −1,314,957。复跑回读内容完全一致，核内计算周期为 965,557 拍。已布线检查点有 46 个 `pv_hi_reg` 乘法器收到动态 `OPMODE[5:4]`，同时 48 位 `PCIN` 全接地。其中 41 个的下方相邻 DSP 站点有布局单元。诊断记录位于 `build/mac_routed/cascade.csv`。

`split_bram_pv` 用同一奇项乘法器处理完整 Q24 概率和值相乘，省去原 `pv_hi_reg` 和该级联路径。查询键计算仍使用有符号十六位低字，权重投影仍使用高低字拆分。五个演示向量已通过 12 层逐位回归，时钟周期与之前的仿真一致。日志位于 `build/vlt_split_bram_pv`。

单个 32 通道乘加阵列的 Vivado OOC 对照中，DSP 从 98 降至 66，LUT 从 7,104 增至 7,338，动态选择却接地的 PCIN 候选从 64 降至 0。对照报告位于 `build/mac_split_bram` 和 `build/mac_split_bram_pv`。

修订版全核检查点为 `build/ooc_split_bram_pv/w4_full_stream.dcp`。30 ns 周期下的独立综合估计为 WNS +10.913 ns、WHS +0.046 ns。板级布线使用 40,898 LUT、146.5 块等效 BRAM36 和 194 个 DSP，WNS +4.773 ns、WHS +0.014 ns。消除 DSP 级联告警后，实板各样本的末层回读与早期构建逐字相同。每个样本的 99 行回读逐字重复，整核实板数值仍待修复。

`sample_250` 的慢速装载仿真以 `SYNTHESIS` 宏编译，每 256 字插入空闲，并在各层结束后延迟送入下一层参数。装载 100,174 字的 CRC32 为 `274d5e74`，与主机发出的 400,696 字节流一致。12 层和末层回读均逐字通过，扣除等待的核内周期仍为 965,557 拍。日志位于 `build/vlt_split_bram_pv_paced_synth/sample_250.log`。

`ac_pair_x` 独立综合网表通过 6,336 个激活地址及 5 组并行回读对比。功能网表仿真需保留器件库的原始时间单位，使全局复位在 100 ns 结束。日志位于 `build/activation_ooc/activation_gate_native.log`。

## MAC 符号修订

旧全核功能网表准确接收 `sample_250` 的 6,336 个输入写事务，但首层写回地址 0 产生 `fff745d5`，参考是 `ffda1f91`。实板 ILA 在相同写事务捕获 `fff745d5`，把差异定位到核内运算。旧网表日志位于 `build/gate_split_bram_pv/sample_250.log`。

从旧整核网表提取的 32 路 MAC 与 RTL 对拍时，奇项低位乘法器输入 `B` 丢失符号扩展。修复低位乘积后，部分 lane 仍在累加入口产生 `2^42` 的偏差。`split_bram_pv_signed` 的低位乘法和两路通道重定标都使用显式有符号 DSP48E2，偶高、奇高及重定标分片用明确的符号扩展和零填充组合，并把奇项直接展开到 44 位累加宽度。

修订后的单 MAC OOC 使用 7,872 LUT 和 66 个 DSP。其功能网表在三种模式、32 条 lane 和四种点积长度下通过 384 个输出对比。日志位于 `build/mac_gate_signed_signextend/mac_gate_signed_signextend.log`。最终五个完整 RTL 样本也通过 12 层和末层逐字对比，每次有效计算 965,557 拍，日志位于 `build/vlt_split_bram_pv_signed`。

从同一整核网表提取的一路 LayerNorm 也复测了首层两套参数的 256 字装载和四行共 256 个归一化输出，结果及列标记与 RTL 逐字一致。日志位于 `build/ln_gate/ln_gate_connected.log`。

最终源码可直接独立综合为 `build/ooc_split_bram_pv_signed/w4_full_stream.dcp`。全核使用 42,453 LUT、146 块等效 BRAM36 和 194 个 DSP。综合后分别余 4,779 LUT、4 块 BRAM36 和 46 个 DSP 供板端外壳使用。30 ns 时钟下的综合后估计为 WNS +10.938 ns、WHS +0.046 ns。

全核检查点内的 EDIF 还显示了跨层次综合的差异。纯 RTL 重新综合后，两组 MAC 的全部 64 路奇项原语 `u_odd_low/u_product` 再次把 `B[17]` 和 `B[16]` 固定为 `[]<const0>`，实际符号只到 `B[15]`。对应偶项的 `B[17:15]` 三位均接正确符号。使用单阵列检查点替换的 EDIF 版保留了奇、偶两路的符号连线，实板末层仍有数值差异。

局部候选 `split_bram_pv_signed_b16` 按 W4 的有符号十六位权重约束，从 `b[15]` 复制 DSP 的 `B[17:15]`，并在投影乘法器保留层次连接。单阵列综合使用 7,872 LUT 和 66 个 DSP，64 路偶、奇项原语的 `B[17:15]` 均来自 `b[15]`。它的 XSIM 功能网表通过 384 个输出的同周期比对。证据位于 `build/mac_split_bram_pv_signed_b16` 和 `build/mac_gate_signed_b16/mac_gate_signed_b16.log`，验证范围为独立阵列。
