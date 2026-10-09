# BTB 与动态分支预测（代码准备，验证待完成）

本次在 `D:\FPGA\riscv_3stage` 增加可选的 BTB 与 2 位条件分支预测器。
按照用户暂时不验证的安排，2026-10-08 只准备源代码、构建入口、未来自检平台和说明。
本轮未执行 GCC、ModelSim、PDS 或上板验证，没有新的 CoreMark 成绩。
此前 CPU、I Cache、CoreMark 的通过记录属于此前的版本；本次修改后的兼容性仍待回归。

## 实现范围

`rtl/branch_predictor.v` 默认包含 64 项直接映射 BTB，每项保存完整 PC tag、目标地址、条件分支方向计数器和 JAL 标记。
`BTB_ENTRIES` 可配置为 1～1024 中的 2 的幂。默认 64 项对应 `(PC >> 2) & 63` 索引；完整 tag 避免索引冲突误用其他 PC 的表项。

- 条件分支：支持 BEQ、BNE、BLT、BGE、BLTU、BGEU。首次完成时按实际方向初始化为弱跳转 `10` 或弱不跳转 `01`，后续用 2 位饱和计数器训练。
- JAL：保存目标，命中时预测跳转。
- JALR：仍按现有 EX 跳转处理，不分配预测表项。普通指令或 JALR 完成时会清除同 PC 的旧表项，避免代码替换后反复使用旧预测。
- 非 4 字节对齐的 PC 或目标不用于预测；实际异常判断继续由现有 CPU 逻辑完成。
- 未命中或预测不跳转时，下一取指地址为 `PC + 4`。

CPU、取指阶段和 AXI SoC 的 `ENABLE_BRANCH_PRED` 默认均为 `0`。新增 `btb_board_top` 显式打开预测器；已有板级配置和 AXI CoreMark 开关版本继续保持预测器关闭。
本次不增加新的 CoreMark 预测器对照镜像，也不改变既有成绩标签。
取指继续采用工程已有的只读 ROM 假设。同 PC 旧表项失效用于防御性恢复，并不提供自修改代码或 `FENCE.I` 的一致性支持。

## 预测与恢复

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
| `0x78` | hit | 上述请求中 BTB tag 命中数 |
| `0x7c` | predicted taken | 上述请求中预测跳转数 |
| `0x80` | resolved | 正常完成的条件分支和 JAL 数，不包括 JALR |
| `0x84` | next-PC mismatch | 所有正常完成指令中预测下一 PC 与实际下一 PC 不符数，包括 JALR 和普通指令旧表项 |
| `0x88` | direction error | 可预测控制指令中预测跳转方向与实际方向不符数 |
| `0x8c` | target error | 可预测控制指令中预测和实际均跳转、但目标不同的次数 |

`next-PC mismatch / resolved` 不是分支预测错误率，因为两项计数覆盖的指令范围不同。
hit/lookup 只表示 BTB tag 命中比例，也不是方向预测准确率。
板级固件逐个读取这些寄存器，诊断快照不是原子采样，包含读取快照时执行的指令。

## 后续准备运行的入口

当前仅有源代码；下列命令是以后恢复验证时使用的操作步骤。

在 Git Bash 中构建独立板级固件与 PDS 位流：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_btb_board.bat
cmd.exe //c build_pds_board.bat --variant btb_board --firmware btb_board --stage bitstream
```

固件构建入口会生成硬件 `.hex`、硬件数据 `.hex`、缩短心跳等待的仿真数据 `.hex`、symbols header 和构建报告。
硬件与仿真使用相同指令镜像；只有初始化心跳等待值不同。报告用于拒绝缺失、过时或契约不匹配的镜像。
本轮没有运行这些构建命令，因此当前不承诺已有可下载的新位流。

ModelSim 中，工作目录设为工程根目录后：

```tcl
do run_btb.do
# 先构建固件，生成 symbols 与镜像后再运行下面这一项：
do run_btb_board.do
```

`run_btb.do` 使用已有 blank fixture 加入自包含指令流，不依赖新的 GCC 产物。
未来检查内容包括计数器饱和、完整 tag 碰撞、JAL、同 PC 替换失效、held request 的预测快照、旧响应错误丢弃、复位，以及 CPU 的 off/on、本地和外部延迟取指。
CPU 程序覆盖六种分支的双向结果、重复循环退出的方向变化、JAL/JALR link、精确退休 PC 和每次 STORE/MMIO 副作用次数。

`run_btb_board.do` 先校验构建报告再运行板级固件。未来检查真实 50 MHz/115200 UART 的计数行和 PASS/FAIL 字节、RAM 结果、LED、心跳及 KEY1 复位重启。
这些自检源文件已准备，不表示它们已经仿真通过。

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

## 恢复验证后的顺序

1. 先在预测器默认关闭条件下回归已有 CPU、分支、取指/数据握手、trap、timer IRQ 和双 Cache 测试，确认共用前端修改的兼容性。
2. 再运行 BTB 单元与 CPU 定向测试；错误路径、请求背压和 STORE 一次性必须先检查。
3. 构建独立 `btb_board` 固件，运行板级 RTL 仿真，再检查 PDS 资源、时序、网表和实物现象。
4. 通过以上步骤后，再增加相同 Cache/存储/时钟配置的预测器 off/on CoreMark 对照，重新测量 CRC、时长和成绩。

单元测试、RTL、网表、PDS、实物、性能提升在本步骤全部标记为 **待验证**。
