# W4 工艺依赖

功能仿真使用仓库内的 SRAM 行为模型。实体 SRAM 和后端工具从使用者已获授权的 PDK 安装中读取，工艺原文件保留在仓库外。

## SAED32 容器后端

将 `SAED32_EDK` 设为本地 EDK 根目录，从 `asic/w4` 执行检查。

```bash
export SAED32_EDK=/path/to/SAED32_EDK
python3 pdk/check_saed32.py
```

[依赖清单](saed32/files.txt)覆盖实验所用 SRAM 仿真模型、RVT 标准单元及 SRAM 的时序库与 NDM、1P9M 工艺和寄生参数，以及 GDSII 导出所需的层映射和物理视图。脚本检查文件是否存在且可读。完整流程还需要对应工具、E203 整机工程以及同一版本的网表和约束。

| W4 的 SRAM 接口 | SAED32 适配 |
|---|---|
| `RAMSP128X16` | 两个 `SRAM1RW128x8` 并成 16 bit |
| `RAMSP1024X16` | 两个 `SRAM1RW1024x8` 并成 16 bit |
| `RAMSP4096X16` | 四个深度银行，每个银行用两个 `SRAM1RW1024x8` |

硬宏实现编译 `saed32/saed32_byte_sram.sv`、`saed32/w4_saed32_sram_ports.sv` 和 EDK 的 `saed32sram.v`，替代 `sim/w4_sim_sram.sv`。适配器支持 W4 使用的按字节写入，读返回保持在上次读取的银行。可单独用 VCS 复查三个深度，测试输入由仿真生成。

```bash
asic_root="$PWD"
test_dir=$(mktemp -d)
(
  cd "$test_dir" &&
  vcs -full64 -sverilog -timescale=1ns/1ps -top tb_sram_adapter \
    "$SAED32_EDK/lib/sram/verilog/saed32sram.v" \
    "$asic_root/pdk/saed32/saed32_byte_sram.sv" \
    "$asic_root/pdk/saed32/w4_saed32_sram_ports.sv" \
    "$asic_root/pdk/saed32/tb_sram_adapter.sv" -o simv &&
  ./simv
)
```

## SMIC40 比赛平台

SMIC40 流程由比赛平台提供工艺库。按批准的工艺角选择逻辑和 SRAM 时序视图，物理实现还需同版本的技术文件、寄生模型、层映射和 SRAM 物理视图。所需 SRAM 接口为 `RAMSP128X16`、`RAMSP1024X16` 和 `RAMSP4096X16`。从平台取得对应库后，通过工程的库搜索路径或 EDA 脚本引用。
