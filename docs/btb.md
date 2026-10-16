# BTB 与动态分支预测（AXI 正式跑分已配对）

本次在 `D:\FPGA\riscv_3stage` 增加可选的 BTB 与 2 位条件分支预测器。
按照用户暂时不验证的安排，2026-10-08 只准备源代码、构建入口、未来自检平台和说明。
该源码准备阶段未执行 GCC、ModelSim、PDS 或上板验证，没有新的 CoreMark 成绩。

**2026-10-14 更新：** 已核对本地统一回归，BTB 单元／CPU 定向测试和 AXI 三配置六种 CoreMark 短程测试均为 PASS。修复 BTB 板级固件的链接对齐错误后，用户截图确认独立板顶 RTL 仿真通过；随后补齐 CPU 实例的 8 个未连接端口，重新构建匹配固件，并在独立临时工作库复核现有板顶测试，结果为 0 错误、0 警告、`test_pass=1`、`done=3`。本版本 PDS、综合后行为与实物仍待验证，新配置的正式 CoreMark 成绩仍待测量。

## 实现范围

**2026-10-16 更新：** AXI CoreMark 专用 BTB performance 版本已完成取指／统计时序修正并生成 50 MHz 位流，实际最终 setup 裕量 0.383 ns、最小 hold 裕量 0.055 ns；五项相关回归与六种 AXI 短程用例通过。新增测试覆盖重定向当拍预测旁路、随后恢复预测及待计数事件的复位清除。performance 与同配置 validation 均已实测 `FORMAL PASS`；三种 AXI 配置共六项正式运行全部配对完成。BTB 性能引用 performance 的 **49.603719 CoreMark、0.992074389 CoreMark/MHz**，比双 Cache 配置快 **7.72%**、比 AXI 无 Cache 基线快 **30.17%**；增幅包含各自固件布局与实现差异，按配置整体实测解释。此记录属于 `coremark_axi_btb`，独立 `btb_board` 的专项综合网表与实物验收仍待完成。位流、时序与回归证据见[板级测量记录](coremark_axi_results_20261015.md)。

BTB validation 运行 600 次，耗时 12.772387720 秒，统计窗口 CPI 为 1.355283420，seed／list／matrix／state CRC 为 `18f2`／`e3c1`／`0747`／`8d84`。其 46.976337796 次／秒仅为校验速度，不与 performance 求平均。I Cache 填充字数比缺失数四倍多 3，是 START／STOP 不等待正在进行的填充排空时允许出现的净边界差，不推断某一笔具体事务。

`rtl/branch_predictor.v` 默认包含 64 项直接映射 BTB，每项保存完整 PC tag、目标地址、条件分支方向计数器和 JAL 标记。
`BTB_ENTRIES` 可配置为 1～1024 中的 2 的幂。默认 64 项对应 `(PC >> 2) & 63` 索引；完整 tag 避免索引冲突误用其他 PC 的表项。

- 条件分支：支持 BEQ、BNE、BLT、BGE、BLTU、BGEU。首次完成时按实际方向初始化为弱跳转 `10` 或弱不跳转 `01`，后续用 2 位饱和计数器训练。
- JAL：保存目标，命中时预测跳转。
- JALR：仍按现有 EX 跳转处理，不分配预测表项。普通指令或 JALR 完成时会清除同 PC 的旧表项，避免代码替换后反复使用旧预测。
- 非 4 字节对齐的 PC 或目标不用于预测；实际异常判断继续由现有 CPU 逻辑完成。
- 未命中或预测不跳转时，下一取指地址为 `PC + 4`。

CPU、取指阶段和 AXI SoC 的 `ENABLE_BRANCH_PRED` 默认均为 `0`。`btb_board_top` 显式打开预测器；已有板级配置和 AXI CoreMark off/on 版本继续保持预测器关闭。
2026-10-10 新增 `coremark_axi_btb` 三配置对照入口，开启双 Cache 和 64 项 BTB，采用独立镜像名。该入口也只准备代码，尚未构建镜像或测量成绩；原有成绩标签保持原样，见 [AXI CoreMark 说明](coremark_axi.md)。
取指继续采用工程已有的只读 ROM 假设。同 PC 旧表项失效用于防御性恢复，并不提供自修改代码或 `FENCE.I` 的一致性支持。

## 预测与恢复

2026-10-16 的取指时序调整让 BTB 从寄存的 `pc_f` 查询，避免晚到的 EX 重定向再穿过 BTB 索引／tag／目标选择。首次呈现的新请求若当拍存在 redirect，则使用重定向地址的 `PC + 4` 作为预测后继，hit／taken 元数据为 0；之后从寄存 PC 发出的请求恢复正常预测。已 held 的请求仍保留首次呈现时的预测快照，redirect 通过既有 stale 机制处理。该策略可能改变预测覆盖率和性能，需要使用本版固件与位流实测。

IF 在取指请求首次呈现时保存预测结果。请求因 ready 背压而等待时，地址和预测元数据保持不变；即使此时 EX 更新了 BTB，也使用该请求原来的预测快照。
请求接受后，PC、预测下一 PC、hit/taken 标记随该请求保存，响应进入 EX 时一起传递。数据访问 stall 期间，EX 指令和预测快照一起保持。

EX 在指令正常完成时比较实际下一 PC 与该指令的预测下一 PC。跳转目标、分支方向或普通指令的旧预测出现差异时，redirect 到实际下一 PC，清除年轻指令。
已经接受的旧取指响应和未接受的 held request 按原有 stale 机制排空，避免破坏请求契约或将错误路径指令/错误响应送入 EX。
访存指令等待成功响应后才完成预测核对，避免重复 STORE/MMIO 副作用。
trap 和 MRET 的 redirect 优先级高于普通预测恢复；发生异常或被中断抢占的指令不训练预测器。

这一步继续使用工程已有的 M 模式异常、CSR、MRET 和机器定时器中断逻辑，不代表实现了完整 RISC-V 特权架构。

## 只读诊断寄存器

以下寄存器在预测器开启时属于 CPU 内部 MMIO，地址为 `0x20000000 + offset`，只接受对齐的 32 位 `LW`；写入和子字访问返回错误。
计数均为无符号 32 位，复位清零。预测器关闭时内部诊断计数信号为零，但 `0x70`～`0x8c` 不映射为 MMIO，读取这些地址返回错误。

| Offset | 字段 | 含义 |
| --- | --- | --- |
| `0x70` | 配置 | 高 16 位为 BTB 项数，bit 0 为启用标志；默认开启值 `0x00400001` |
| `0x74` | lookup | 接受且未被标记 stale 的取指请求数 |
| `0x78` | hit | 上述请求中采用的 BTB tag 命中数；当拍重定向旁路记 0 |
| `0x7c` | predicted taken | 上述请求中预测跳转数 |
| `0x80` | resolved | 正常完成的条件分支和 JAL 数，不包括 JALR |
| `0x84` | next-PC mismatch | 所有正常完成指令中预测下一 PC 与实际下一 PC 不符数，包括 JALR 和普通指令旧表项 |
| `0x88` | direction error | 可预测控制指令中预测跳转方向与实际方向不符数 |
| `0x8c` | target error | 可预测控制指令中预测和实际均跳转、但目标不同的次数 |

`next-PC mismatch / resolved` 不是分支预测错误率，因为两项计数覆盖的指令范围不同。
hit/lookup 表示按接受请求统计的有效 BTB 命中比例，分母也包含当拍重定向旁路请求，不是方向预测准确率。
lookup／hit／predicted-taken 三类完整事件在 IF 内统一寄存一拍后累加，复位同时清事件和计数。前三类统计可见性晚一拍，原子窗口不补偿边界事件。
板级固件逐个读取这些寄存器，诊断快照不是原子采样，包含读取快照时执行的指令。

AXI CoreMark 顶层另在 `0x30000000` 提供 schema 2 原子统计接口：读取 `+0`／`+4` 时同时冻结周期、退休、Cache 和七项 BP 字段；BP START 位于 `+0xc0`～`+0xd8`，STOP 位于 `+0xe0`～`+0xf8`。预测关闭时该专用 BP 银行返回零，配置 `+0x14` 为 `0x00400000`；开启为 `0x00400001`。这不改变上述 CPU 本地 MMIO 的关闭模式映射规则。

## 构建与仿真入口

以下命令用于独立板级固件、PDS 与板顶 RTL 仿真。各步骤的通过状态应分别记录。

在 Git Bash 中构建独立板级固件与 PDS 位流：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_btb_board.bat
cmd.exe //c build_pds_board.bat --variant btb_board --firmware btb_board --stage bitstream
```

固件构建入口会生成硬件 `.hex`、硬件数据 `.hex`、缩短心跳等待的仿真数据 `.hex`、symbols header 和构建报告。
BTB 固件使用专用 `software/link_btb.ld`，ROM、RAM、栈和 `tohost` 地址沿用公共布局；`.text` 内的链接对齐空隙填充为 RV32I NOP。此修复针对 256 字节对齐引起的 `Non-RV32I instruction 0x00000000 at 0x00000040` 构建错误，保留整段指令检查、CSR 白名单与冲突分支同索引／不同 PC 检查。公共 `software/link.ld` 保持原样；构建成功后仍须单独运行板顶仿真，不能据此记为上板通过。
2026-10-14 构建结果：硬件／仿真代码均为 2568 字节且逐字节一致；`0x40`～`0xff` 的 192 字节空隙为 48 条合法 NOP，冲突分支 PC 仍为 `0x308` 和 `0x408`。构建报告和新链接脚本哈希守卫通过；在镜像副本中注入零字、RV32M MUL 或非白名单 WFI 均被拒绝。此项检查确认构建与镜像，板顶 RTL 复核结果另列如下。

同日补齐 `btb_board_top` 的 CPU 实例：未使用的 `irq_external` 绑零，七个 BP 观测输出显式空连接，外部／软件中断参数明确关闭。固件仍通过 CPU 内部 MMIO 读取统计。重新构建后，用现有 `run_btb_board.do` 与 `tb/btb_board_tb.v` 在独立工作库验证，正常重启和强制失败两个场景完成，打印完整 `BTB BOARD TESTS PASS`，退出码 0，`test_pass=1`、`done=3`，0 错误、0 警告；编译和运行输入前后哈希一致。本地日志和源文件身份记录位于 `build/verification/btb_ports_20261014_90baa4aa3f3d/`。这些记录属于 RTL 仿真，不是上板或正式成绩。
硬件与仿真使用相同指令镜像；只有初始化心跳等待值不同。报告用于拒绝缺失、过时或契约不匹配的镜像。
2026-10-14 已完成修复后的固件构建，尚未执行本版本 PDS 构建，位流仍待生成与验收。

ModelSim 中，工作目录设为工程根目录后：

```tcl
do run_btb.do
# 先构建固件，生成 symbols 与镜像后再运行下面这一项：
do run_btb_board.do
```

`run_btb.do` 使用已有 blank fixture 加入自包含指令流，不依赖新的 GCC 产物。
定向测试检查计数器饱和、完整 tag 碰撞、JAL、同 PC 替换失效、held request 的预测快照、旧响应错误丢弃、复位，以及 CPU 的 off/on、本地和外部延迟取指。
CPU 程序覆盖六种分支的双向结果、重复循环退出的方向变化、JAL/JALR link、精确退休 PC 和每次 STORE/MMIO 副作用次数。

`run_btb_board.do` 先校验构建报告再运行板级固件，检查真实 50 MHz/115200 UART 的计数行和 PASS/FAIL 字节、RAM 结果、LED、心跳及 KEY1 复位重启。
`run_btb.do` 的单元与 CPU 定向测试已有统一回归 PASS 记录；独立板顶 RTL 在链接与端口修复后也已通过，PDS 和实物验收仍待完成。

板级固件预期正常输出：

```text
BTB COUNTERS XXXXXXXX XXXXXXXX XXXXXXXX XXXXXXXX XXXXXXXX XXXXXXXX XXXXXXXX
BTB BOARD PASS
```

七项数值按 lookup、hit、predicted taken、resolved、next-PC mismatch、direction error、target error 的顺序输出。
正常时 LED bit 1 常亮、bit 0 心跳变化，KEY1 按下后复位，再运行一轮自检。
失败时 LED bit 2 常亮，输出 `BTB BOARD FAIL <failure bits> <case result>`，等待复位。

| Failure bit | 含义 |
| --- | --- |
| bit 0 | 汇编用例结果非零 |
| bit 1 | 硬件预测器配置错误 |
| bit 2 | 未出现所需的预测活动或恢复计数 |
| bit 3 | 心跳周期配置为零 |
| bit 4 | 意外 trap，先输出 cause/PC/tval，再停止，不能重新启动后覆盖失败 |

## 后续改动的复核顺序

1. 先在预测器默认关闭条件下回归已有 CPU、分支、取指/数据握手、trap、timer IRQ 和双 Cache 测试，确认共用前端修改的兼容性。
2. 再运行 BTB 单元与 CPU 定向测试；错误路径、请求背压和 STORE 一次性必须先检查。
3. 构建独立 `btb_board` 固件，运行板级 RTL 仿真，再检查 PDS 资源、时序、网表和实物现象。
4. AXI 基线／双 Cache／双 Cache＋BTB 的六项正式运行现已配对完成；后续修改相关实现后，按 [AXI CoreMark 说明](coremark_axi.md) 重建短镜像并完成六种组合，再生成正式镜像与位流，重新测量 CRC、时长和成绩。该测量不能替代独立 `btb_board` 的专项验收。

单元／CPU 定向测试、独立板顶 RTL 与 AXI CoreMark 短程组合已有仿真 PASS。独立 `btb_board` 的专用综合网表入口、PDS 与实物验收仍待完成；AXI CoreMark BTB performance／validation 均已实测 `FORMAL PASS`，三种 AXI 配置的六项正式运行全部配对完成。BTB 性能为 49.603719 CoreMark／0.992074389 CoreMark/MHz，详见[最新测量记录](coremark_axi_results_20261015.md)。
