# AXI SoC 的 CoreMark：Cache 关闭／开启对照

本入口用于在同一 AXI SoC 上对比 Cache 关闭和 I/D Cache 同时开启的效果。新增代码于 2026-10-08 整理；根据用户本轮“暂时不验证”的要求，未执行固件编译、ModelSim 仿真、PDS 综合及时序检查、实物上板或成绩测量。本文中的命令供后续验证使用，文中的 PASS 和位流路径均为预期，不表示已经完成验证。

原有 `build_coremark.bat`、CoreMark 移植层、无 Cache 顶层及 `programs/coremark_performance*`、`programs/coremark_validation*` 保留原样。原先上板得到的 **52.574739 CoreMark、1.051494774 CoreMark/MHz（50 MHz）** 仍为内部 RAM 版本的历史基线。新版本使用 AXI RAM，不能将它与历史基线之间的差异全部归因于 Cache。

## 对照配置

| 项目 | Cache 关闭 | Cache 开启 |
| --- | --- | --- |
| 构建选项 | `--cache off` | `--cache on` |
| PDS variant | `coremark_axi_off` | `coremark_axi_on` |
| SoC 与存储器 | 同一 AXI SoC、ROM 32 KiB、RAM 16 KiB | 同左 |
| ROM / RAM 地址 | `0x00000000` / `0x00010000` | 同左 |
| 人工 RAM 等待参数 | 0 | 0 |
| 正式时钟 / 串口 | 50 MHz / 115200、8N1 | 同左 |
| I Cache / D Cache | 均关闭 | 均为 2 KiB、2 路、64 组、16 字节行、LRU |
| D Cache 写策略 | 经 AXI 写 RAM | 写穿透、不在写缺失时分配缓存行 |
| MMIO | 旁路 | 旁路，不缓存外设寄存器 |
| 编译配置 | RV32I、ILP32、`-O2`，沿用原 CoreMark 基础选项 | 同左 |

人工等待参数为 0 仍存在 AXI 握手和同步存储器访问周期。两个版本采用相同的总线与 RAM 配置。上游 CoreMark 算法源文件保持原样。

## 独立构建入口

在工程根目录使用 `build_coremark_axi.bat`，它调用 `tools/build_coremark_axi_images.py`。

支持的参数为：

- `--cache off|on|both`：`both` 串行构建关闭和开启两个版本。
- `--profile performance|validation|smoke|smoke-validation|formal-short`。
- `--iterations N`：正式版本的 0 表示自动校准；正整数指定迭代次数。短功能测试应使用正整数。
- `--cross PREFIX`：可选的 RISC-V 工具链前缀，包含末尾的 `-`。

输出名字自动生成为 `axi_cache_<off或on>_<profile>`，其中 profile 的连字符替换为下划线。新入口不提供 `--name`，避免复用或覆盖历史镜像的名字。

例如 performance 的输出为：

```text
programs/coremark_axi_cache_off_performance.hex
programs/coremark_axi_cache_off_performance_data.hex
programs/coremark_axi_cache_off_performance_config.vh
build/coremark/axi_cache_off_performance/

programs/coremark_axi_cache_on_performance.hex
programs/coremark_axi_cache_on_performance_data.hex
programs/coremark_axi_cache_on_performance_config.vh
build/coremark/axi_cache_on_performance/
```

每个目录保存对应固件的构建报告和产物；仅保存或提交本次源代码不会生成这些镜像。

## 后续短仿真

先在 Git Bash 构建两个 Cache 配置和两组种子的短镜像：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_coremark_axi.bat --cache both --profile smoke
cmd.exe //c build_coremark_axi.bat --cache both --profile smoke-validation
```

然后在 ModelSim Transcript 执行：

```tcl
cd D:/FPGA/riscv_3stage
do run_coremark_axi.do
```

该入口先运行统计模块的独立自检，再覆盖四种固件组合：Cache off/on，各运行 performance 和 validation 种子的短测试。统计自检检查开始／结束银行、64 位计数采样、Cache 字段、硬件配置、总线背压、只读错误和复位。短测试用于检查功能、CRC、报告字段和统计接口，不能作为正式 CoreMark 成绩。`formal-short` 用于检查正式模式对过短运行的拒绝，不是可上板报告成绩的正式固件。

短固件使用 50 MHz 核心时钟和 5 Mbps 的仿真串口，以缩短日志输出的仿真时间；正式上板固件仍使用 115200 波特率。上游算法会提示短运行不足 10 秒，这属于 smoke 的预期提示；须结合 CRC 和最终 `SMOKE PASS` 判断功能，不能引用短运行速度作为正式成绩。

## 后续正式固件

在 Git Bash 分别构建四个版本：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_coremark_axi.bat --cache off --profile performance
cmd.exe //c build_coremark_axi.bat --cache on --profile performance
cmd.exe //c build_coremark_axi.bat --cache off --profile validation
cmd.exe //c build_coremark_axi.bat --cache on --profile validation
```

performance 和 validation 默认自动校准迭代次数。比较正式速度时，两种 Cache 配置的自动迭代次数可以不同。若还要按相同工作量比较计数，使用相同的 `--iterations N` 重新构建两个对应版本，并确保两者正式测量时间均达到 10 秒。

## 后续 PDS 构建与上板

固件构建成功后，再分别生成四个位流：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_pds_board.bat --variant coremark_axi_off --firmware coremark_axi_cache_off_performance --stage bitstream
cmd.exe //c build_pds_board.bat --variant coremark_axi_on --firmware coremark_axi_cache_on_performance --stage bitstream
cmd.exe //c build_pds_board.bat --variant coremark_axi_off --firmware coremark_axi_cache_off_validation --stage bitstream
cmd.exe //c build_pds_board.bat --variant coremark_axi_on --firmware coremark_axi_cache_on_validation --stage bitstream
```

PDS 目录互相独立：

| 固件 | 成功完成后预期的位流路径 |
| --- | --- |
| off / performance | `build/pds_coremark_axi_cache_off_performance/generate_bitstream/board_top.sbit` |
| on / performance | `build/pds_coremark_axi_cache_on_performance/generate_bitstream/board_top.sbit` |
| off / validation | `build/pds_coremark_axi_cache_off_validation/generate_bitstream/board_top.sbit` |
| on / validation | `build/pds_coremark_axi_cache_on_validation/generate_bitstream/board_top.sbit` |

构建守卫核对固件配置、构建报告、源文件和镜像哈希，并核对 Cache 开关与目标 variant。将 on 固件用于 off variant、使用仿真时钟镜像或使用过期镜像，都应被拒绝。最终位流还须通过 PDS 时序检查；本轮没有运行这些检查。

后续由用户在 PDS 中手动下载相应位流，SSCOM 使用 115200、8N1 接收日志。每个版本应完整输出运行参数、CRC、耗时、速度、平台和 Cache 配置。满足正式运行时间及 CRC 等检查后，预期结束行为为 `COREMARK RESULT: FORMAL PASS`。接收窗口的分包不会改变日志内容，保存日志时应保留完整字段。

## Cache 计数、CPI 和计时边界

统计接口使用两组采样银行，保存开始和结束时的 I/D Cache 计数，以及 64 位周期数、退休指令数。固件在 `start_time` 的 mtime 计时开始前触发开始采样，在 `stop_time` 的 mtime 计时结束后触发结束采样；统计读取和串口打印在测量结束后进行。

两次采样的差值可用于观察命中、缺失、填充、写入、旁路和错误情况。CPI 由统计窗口中的周期差与退休指令差计算。**统计窗口包含边界采样开销，与 mtime 的正式测量窗口不完全重合**，不能将这些计数描述为严格的正式计时区间计数。CoreMark 速度仍由 mtime 耗时计算。

Cache 计数器为 32 位，周期数和退休指令数为 64 位。若统计窗口周期差达到 `2^32`，Cache 差值会标记为无效，避免对多次回绕作错误解释；该标记本身不否定通过时间、CRC 等检查的正式 CoreMark 分数。周期差或退休指令差不满足计算条件时，不应报告有效 CPI。

自动校准会提前运行算法，因此正式运行通常已有热 Cache。当前报告应注明这一点；没有实施每轮清空 Cache 的冷启动测量。

专用统计设备的基地址为 `0x30000000`，所有寄存器只读，写入及无效／未对齐读取返回 AXI `SLVERR`。

| 偏移 | 含义 |
| --- | --- |
| `0x00` | 读取时冻结 START 银行，并返回设备 ID `0x434d4158` |
| `0x04` | 读取时冻结 STOP 银行，并返回同一 ID |
| `0x08` | 实际硬件开关：bit0 为 I Cache，bit1 为 D Cache；off 为 0，on 为 3 |
| `0x0c`／`0x10` | I／D Cache 几何配置：默认 `0x02400010`，分别编码 2 路、64 组、16 字节行 |
| `0x40`～`0x7c` | START 银行，共 16 个 32 位字 |
| `0x80`～`0xbc` | STOP 银行，共 16 个 32 位字 |

两银行顺序均为：周期数低／高 32 位、退休指令数低／高 32 位、I Cache 的访问／命中／缺失／填充字／错误、D Cache 的访问／命中／缺失／填充字／错误／写入／旁路。触发读取在 AXI AR 握手时同时采样所有字段；后续读取只返回冻结值。两银行独立，新的 START 不覆盖上一次 STOP。

D Cache 的访问数包含写请求和旁路请求。若自行计算 RAM 读取命中率，使用 `hit / (hit + miss)`，不要把写入和旁路放入读取命中率分母。填充可能跨过窗口边界，不能要求窗口差值严格满足“填充字数 = 缺失数 × 4”。

## 如何记录结果

后续验证时，每份记录应绑定固件输出名字、构建报告、PDS 清单、对应位流和完整串口日志。保留两个正式 performance 结果，确认对应 validation 均通过，再比较 Cache off/on 的 CoreMark/MHz；同时记录实际迭代次数和统计有效性。

固件构建或位流生成不能代替实物测量。当前新增版本的功能、仿真、时序、实物状态和正式成绩均待验证，暂不填写成绩或 PASS 记录。
