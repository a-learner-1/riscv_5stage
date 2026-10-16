# AXI CoreMark：基线、双 Cache、双 Cache＋BTB 对照

**更新：2026-10-16。** 三配置六种短程测试已通过统一 ModelSim 回归，三配置的 performance／validation 共六项正式运行也均已实测 `FORMAL PASS`，全部配对完成。AXI 无 Cache／无 BTB 基线为 **38.108122 CoreMark、0.762162439 CoreMark/MHz（50 MHz）**。双 Cache／无 BTB 为 **46.049672 CoreMark、0.920993449 CoreMark/MHz**，相对基线提升 **20.84%**；双 Cache＋BTB 为 **49.603719 CoreMark、0.992074389 CoreMark/MHz**，比双 Cache 快 **7.72%**、比 AXI 无 Cache 基线快 **30.17%**。性能均引用各自 performance 运行。完整数据与证据范围见[板级测量记录](coremark_axi_results_20261015.md)。

原有 `build_coremark.bat`、内部 RAM 移植层及历史镜像保持原样。原先的 **52.574739 CoreMark、1.051494774 CoreMark/MHz（50 MHz）** 属于内部 RAM 无 Cache 版本。新版本使用 AXI RAM，分析 Cache 与 BTB 效果应在下面三个配置之间比较。

## 三个配置

| 项目 | AXI 基线 | 双 Cache | 双 Cache＋BTB |
| --- | --- | --- | --- |
| 固件选项 | `--cache off --btb off` | `--cache on --btb off` | `--cache on --btb on` |
| PDS variant | `coremark_axi_off` | `coremark_axi_on` | `coremark_axi_btb` |
| 固件名字前缀 | `coremark_axi_cache_off_` | `coremark_axi_cache_on_` | `coremark_axi_cache_on_btb_` |
| I/D Cache | 均关闭 | 均开启 | 均开启 |
| 动态分支预测 | 关闭 | 关闭 | 64 项 BTB、条件分支 2 位计数器，预测 JAL |
| BTB 配置寄存器 | `0x00400000` | `0x00400000` | `0x00400001` |

共同条件为 50 MHz 核心时钟、32 KiB ROM、16 KiB AXI RAM、核心与存储时钟 1:1、全部人工等待参数为 0、RV32I／ILP32／`-O2`、上游 CoreMark 算法不修改。ROM 为 `0x00000000`～`0x00007fff`，RAM 为 `0x00010000`～`0x00013fff`。人工等待为 0 仍有实际 AXI 握手与同步存储器延迟。

I/D Cache 均为 2 KiB、2 路、64 组、16 字节行、LRU。D Cache 写穿透、写缺失不分配；RAM 范围之外旁路，外设不缓存。预测器只训练条件分支和 JAL，JALR 继续在 EX 解析。详见 [Cache 说明](dcache.md) 和 [BTB 说明](btb.md)。

## 固件构建入口

保留原有 `build_coremark_axi.bat`，新增 `build_coremark_compare.bat`，一次解析公共参数后串行构建三个配置。仅提交源代码不会生成固件。

- `--profile performance|validation|smoke|smoke-validation|formal-short`。
- `--iterations N`：正式模式默认 0，自动校准；正整数指定迭代次数。短模式默认 1，不能指定 0。
- `--cross PREFIX`：可选工具链前缀，包含末尾的 `-`。
- 原入口继续支持 `--cache off|on|both`，默认 `both`；新增 `--btb off|on`，默认 `off`。
- `--btb on` 要求明确指定 `--cache on`，拒绝 `off` 和 `both`。
- 对照入口等价于 `build_coremark_axi.bat --compare all`，不能同时传 `--cache` 或 `--btb`，避免改变三组配置。

输出使用独立名字。以 performance 为例：

```text
programs/coremark_axi_cache_off_performance.hex
programs/coremark_axi_cache_on_performance.hex
programs/coremark_axi_cache_on_btb_performance.hex
```

每个名字还有配套 `_data.hex`、`_config.vh`；ELF、MAP、反汇编和构建报告保存在 `build/coremark/axi_cache_<配置>_<profile>/`。新增 BTB 名字不会覆盖原 off/on 名字或内部 RAM 历史镜像。

## 恢复验证后的短仿真

先回归预测器关闭时的 CPU、握手、异常、中断和双 Cache 功能，再执行 BTB 定向自检。随后在 Git Bash 准备六个短镜像：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_coremark_compare.bat --profile smoke
cmd.exe //c build_coremark_compare.bat --profile smoke-validation
```

然后在 ModelSim Transcript 执行：

```tcl
cd D:/FPGA/riscv_3stage
do run_coremark_axi.do
```

脚本先检查镜像、报告与源码的匹配，再运行统计模块自检和三个配置×两组种子的六种短组合。检查范围包括 CRC、真实 mtime 计时、退休计数、Cache／BP 冻结银行、软硬件配置一致性、AXI 背压、只读错误与复位。预测关闭时 BP 银行读零；预测开启时检查实际预测活动。上述短程检查已通过，正式测量按独立结果记录区分。

短镜像使用 50 MHz／5 Mbps 仿真串口，正式镜像使用 50 MHz／115200、8N1。`SMOKE PASS` 只表示短功能检查，不能作为正式分数。`formal-short` 用于检查不足 10 秒的正式运行被拒绝，不属于可报告成绩的固件。

## 正式构建与 PDS

恢复验证后，在 Git Bash 构建三个 performance 和三个 validation 固件：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_coremark_compare.bat --profile performance
cmd.exe //c build_coremark_compare.bat --profile validation
```

固件成功构建后，分别生成匹配位流：

```bash
cmd.exe //c build_pds_board.bat --variant coremark_axi_off --firmware coremark_axi_cache_off_performance --stage bitstream
cmd.exe //c build_pds_board.bat --variant coremark_axi_on --firmware coremark_axi_cache_on_performance --stage bitstream
cmd.exe //c build_pds_board.bat --variant coremark_axi_btb --firmware coremark_axi_cache_on_btb_performance --stage bitstream
cmd.exe //c build_pds_board.bat --variant coremark_axi_off --firmware coremark_axi_cache_off_validation --stage bitstream
cmd.exe //c build_pds_board.bat --variant coremark_axi_on --firmware coremark_axi_cache_on_validation --stage bitstream
cmd.exe //c build_pds_board.bat --variant coremark_axi_btb --firmware coremark_axi_cache_on_btb_validation --stage bitstream
```

目录按固件名隔离；位流的预期路径为 `build/pds_<固件名>/generate_bitstream/board_top.sbit`。例如新增 performance 的路径为 `build/pds_coremark_axi_cache_on_btb_performance/generate_bitstream/board_top.sbit`。

构建守卫核对报告、源码与镜像哈希、Cache／BTB 开关、64 项 BTB、统计 schema 3、时钟／波特率和等待参数。PDS 固定绑定各配置，不允许把 BTB 镜像配给预测关闭的硬件，也不允许混用短镜像。修改过的统计接口要求重新构建配套 off/on 固件；旧报告或旧镜像不能直接沿用。

通过功能与时序检查后，由用户在 PDS 手动下载匹配位流。SSCOM 使用 115200、8N1，保存完整日志。各配置仍须满足 CRC、正式测量至少 10 秒等条件，最终才应输出 `COREMARK RESULT: FORMAL PASS`。当前 AXI 无 Cache、双 Cache、双 Cache＋BTB 的 performance 与 validation 六项均已实测通过并完成配对；构建、时序与实测证据分别保存在测量记录中。

最终 BTB validation 运行 600 次，耗时 **12.772387720 秒**，统计窗口 CPI 为 **1.355283420**，seed／list／matrix／state CRC 为 `18f2`／`e3c1`／`0747`／`8d84`，最终输出 `FORMAL PASS`。校验速度 46.976337796 次／秒不与 performance 求平均。I Cache 填充字数比缺失数四倍多 3，属于下述跨窗口填充的净边界差，不能据此判定失败。

## 原子统计与计时边界

START 触发读取在 mtime 开始前，STOP 在 mtime 结束后。两次触发在各自 AXI AR 握手边沿同时冻结 64 位周期／退休指令计数、12 项 Cache 计数和 7 项 BP 计数。固件在计时结束后读取银行并打印，避免逐个读取活动计数带来的采样偏差。

**统计窗口含边界开销，与正式 mtime 窗口不完全重合。** CPI 为统计窗口周期差／退休指令差，供辅助分析；正式分数仍按原有 mtime 耗时计算。周期和退休指令为 64 位，Cache／BP 为 32 位。窗口周期差达到 `2^32` 时，32 位差值标记无效，避免多次回绕；不能因此直接否定已通过时间／CRC 检查的 CoreMark 分数。

自动校准会预热 Cache、训练预测器。日志明确报告 `cache_state` 和 `predictor_state`；当前不实现每轮清空 Cache／BTB 的冷启动测量。固定迭代次数也不在 START 清空硬件状态。

统计设备基址 `0x30000000`，只读；写入、未映射或未对齐读取返回 AXI `SLVERR`。

| 偏移 | 内容 |
| --- | --- |
| `0x00` | 冻结全部 START 字段，返回 ID `0x434d4158` |
| `0x04` | 冻结全部 STOP 字段，返回同一 ID |
| `0x08` | bit0 I Cache、bit1 D Cache；off 为 0、on 为 3 |
| `0x0c`／`0x10` | I/D Cache 几何 `0x02400010` |
| `0x14` | 高 16 位 BTB 项数，bit0 预测器开关；关闭仍报告表容量 64 |
| `0x18` | 统计接口版本，当前为 2 |
| `0x40`～`0x7c` | 原 START 周期／退休／Cache 银行，16 字 |
| `0x80`～`0xbc` | 原 STOP 周期／退休／Cache 银行，16 字 |
| `0xc0`～`0xd8` | BP START 银行，7 字 |
| `0xe0`～`0xf8` | BP STOP 银行，7 字 |

原 16 字顺序保持：周期低／高、退休指令低／高、I Cache 访问／命中／缺失／填充字／错误、D Cache 访问／命中／缺失／填充字／错误／写入／旁路。BP 两银行顺序均为 lookup、hit、predicted taken、resolved、next-PC mismatch、direction error、target error。新的 START 不覆盖 STOP；后续银行读取只返回已冻结的值。

串口新增 `branch_pred_enable`、`btb_entries`、`btb_config` 和七项 `bp_*` 差值。`bp_lookup` 统计接受且当时未标记 stale 的取指请求，可能包含随后被冲刷的请求；`bp_resolved` 只含正常完成的条件分支与 JAL；`bp_next_pc_mismatch` 则含所有正常完成指令的下一 PC 恢复，包括 JALR。**不能把 next-PC mismatch／resolved 称为分支预测错误率，也不能把 hit／lookup 称为方向预测准确率。**

2026-10-16 的统计时序修正将 IF 的 lookup／hit／predicted-taken 三类完整事件先寄存一拍，再独立累加到 32 位计数器，以缩短晚到的握手／重定向／BTB 查询到统计 CE 的组合路径。统计寄存本身不改变取指和算法计时；前三类 BP 事件的计数可见性晚一拍，START／STOP 仍在原 AR 握手边沿原子冻结，不补偿实时事件。窗口边界计数可能与原实现相差一个事件。

同轮后续调整把 BTB 查询地址改为寄存 `pc_f`，新请求若当拍存在重定向，则以目标地址加 4 为预测后继，并记录 hit／taken 为 0；随后请求恢复正常预测。held 请求的原快照、stale 排空及 EX 错预测恢复保留。lookup 仍计接受且未 stale 的请求，因此分母包含这一重定向旁路。此项影响预测覆盖率，正式 BTB 结果须对应本版源码／位流，不能当作仅统计延迟的改动。

D Cache 访问数包含写入和旁路；读取命中率使用 hit／(hit＋miss)。填充可能跨窗口边界，不能要求差值严格满足“填充字数＝缺失数×4”。

## 比较与记录

每组记录绑定固件名、构建报告、PDS manifest、位流和完整串口日志。三个配置均已完成对应 validation，性能比较使用各自 performance 的 CoreMark/MHz：AXI 基线→双 Cache 对照 Cache 配置；双 Cache→双 Cache＋BTB 对照预测器配置。

自动校准允许实际迭代次数不同。比较相同工作量下的计数时，可对三个配置传相同 `--iterations N`，并确保所有正式运行均达到 10 秒；同时记录每次工作量、统计有效性、资源与时序。三配置六项正式运行均已配对完成；双 Cache 实测提升 20.84%，双 Cache＋BTB 比双 Cache 快 7.72%、比 AXI 无 Cache 基线快 30.17%。各配置独立固件的链接布局也有差异，增幅按配置整体实测解释。

## 统计接口第三版：周期分类

2026-10-16 新增六个互斥的 64 位周期计数器，START／STOP 新银行位于偏移 `0x100`／`0x140`，专用统计从设备窗口扩大到 `0x200` 字节。原 I/D/BP 寄存器地址保留。新固件要求 schema 3，旧固件及其报告须重建；原板级成绩仍属于原版本。分类口径、构建和验证步骤见[周期统计说明](cycle_profile.md)。
