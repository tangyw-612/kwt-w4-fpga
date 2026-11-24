# KWT-1 W4 加速器

这是用于关键词识别的 KWT-1 W4 加速器 ASIC RTL。核心以 32 路乘加阵列复用计算资源，执行 12 层编码。层参数通过双缓冲装载，Softmax、LayerNorm 和 GELU 采用整数数据通路。

| 目录 | 内容 |
|---|---|
| `rtl/` | 22 个 RTL 源文件，覆盖加速器和 NICE 接口。编译顺序见 `rtl/sources.f`。 |
| `sim/` | SRAM 行为模型、乘加边界测试和 NICE 错误处理测试。用例在仿真中生成输入。 |
| `scripts/` | 编译和仿真入口。 |
| [`pdk/`](pdk/README.md) | 工艺依赖说明、SAED32 SRAM 适配和本地库检查。 |

`ac_enc` 是流式计算核心。通过 `ld_valid`、`ld_ready` 和 `ld_word` 写入输入、查找表和各层参数，通过 `start` 启动，再通过 `xr_valid`、`xr_addr` 和 `xr_data` 读取输出。`encoder_nice_core` 在此之上提供适用于 E203 的 NICE 请求、响应及 ICB 访存接口。

## 运行检查

需要 Python 3.8 或更高版本。把所用工具加入 `PATH`，然后在包根目录执行。

```text
python scripts/smoke.py lint
python scripts/smoke.py sim
```

`lint` 用 Verilator 展开 `encoder_nice_core` 并执行静态检查。`sim` 用 Questa/ModelSim 运行乘加边界和 NICE 错误处理测试。日志及临时波形写入 `build/`。

已验证的结果为 MAC 448 项检查通过，NICE 6 个故障处理场景通过。Verilator 展开成功，仍有位宽等告警。

本包覆盖加速器及 NICE 边界。完整整机回归和物理实现另需处理器平台、固件、模型参数与适用工艺库。这里的 SRAM 行为模型覆盖同步读、低有效写掩码及读出保持，用于功能仿真。

LayerNorm 的分组进位改动属于后续门级 ECO。这里提供的是综合输入 RTL。

## 许可证

本目录的项目代码使用 [Apache-2.0](LICENSE)。用户自行取得的工艺库适用各自的授权条款。
