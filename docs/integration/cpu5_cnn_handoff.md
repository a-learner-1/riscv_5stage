# CPU5 与 CNN 接入指南

本指南面向负责 CNN 协处理器的队友。CPU5 已完成独立处理器的板级验证；接下来在新系统顶层组合 CPU、CNN、缓冲区和总线。推荐先用轮询完成一组输入输出，再扩展中断、数据搬运和音频任务。

## 阅读顺序与代码入口

| 顺序 | 文件 | 用途 |
| --- | --- | --- |
| 1 | [cpu5_coremark_board_top.v](../../rtl/cpu5_coremark_board_top.v) | 已验证板级参数、时钟、复位、引脚和 SoC 实例 |
| 2 | [cpu5_stats_axi_lite_top.v](../../rtl/cpu5_stats_axi_lite_top.v) | 完整功能参数的实例化示例；CPU、ROM、AXI 路由及 Stats 连接 |
| 3 | [cpu5_d0_axi_lite_top.v](../../rtl/cpu5_d0_axi_lite_top.v) | 推荐的 CPU5 集成包装：本地 D0 RAM、外部 AXI4-Lite、native 指令端口 |
| 4 | [soc_instr_mem.v](../../rtl/soc_instr_mem.v) | 与包装的 `imem_req_*`、`imem_rsp_*` 相接的指令 ROM |
| 5 | [dmem_axi_lite_bridge.v](../../rtl/dmem_axi_lite_bridge.v) | 单笔在途桥、字节写与错误响应行为 |
| 6 | [axi_lite_1x2.v](../../rtl/axi_lite_1x2.v) | 当前地址路由的参考；增加 CNN 后需按实际从设备数量扩展 |
| 7 | [link.ld](../../software/cpu5_coremark/link.ld)、[mmio.h](../../software/mmio.h) | CPU5 固件存储布局及公共串口接口 |

旧 `cpu_top.v`、`soc_axi_lite_top.v` 是三级实现。独立 `soc_axi_burst_demo_top.v` 是读突发演示，不能直接视作当前 CPU5 的完整 CNN 顶层。

## 已验证的 CPU 基线

CPU5 为 RV32IM、ILP32、小端，五级单发射顺序执行。工作时钟 50 MHz；ROM 32 KiB，D0 RAM 16 KiB，I/D Cache 各 2 KiB，BTB64。MEM 是唯一架构退休点，WB 完成通用寄存器物理写回。CNN 通过总线寄存器与 CPU 通信，不依赖内部 PC、有效位或退休波形产生启动条件。

CoreMark performance 为 128.813667587、2.576273352/MHz；performance 和 validation 各 2000 次并通过 CRC。原始结果、ILA 和配置身份见[板测结果](../cpu5_board_results_20261028.json)及[证据入口](../evidence/cpu5_board_20261028/README.md)。现有结果对应独立 CPU5；加入 CNN 后需要重新核对系统资源、时序与功能。

## 新系统顶层如何组合

建议从 `cpu5_stats_axi_lite_top` 的连接方式建立独立的 CNN 系统顶层：保留指令 ROM和 `cpu5_d0_axi_lite_top`，扩展外部 AXI 地址路由，把 Stats 与 CNN 控制寄存器分别映射。需要数据缓冲区时，把其端口、地址和仲裁也明确放入顶层。

```text
50 MHz / 协调复位
  ├─ soc_instr_mem ← native I 请求/响应 ← CPU5 包装
  ├─ CPU5 包装：五级 CPU + I/D Cache + 本地 MMIO + D0 RAM
  │     ├─ UART / GPIO / mtime / MSIP
  │     └─ m_axi_* → 新系统地址路由
  │                      ├─ Stats
  │                      ├─ CNN 控制寄存器 〔待接入〕
  │                      └─ CNN 数据窗口  〔按实际方案接入〕
  └─ CNN 运算与存储模块 〔队友实现〕
```

`cpu5_coremark_board_top` 是固定配置并带构建保护的性能基线。新顶层应有自己的文件、约束、固件和构建记录。

### 必须显式设置的参数

通用包装保留早期阶段的骨架默认值，不能仅实例化模块就假定启用完整 CPU。复制已验证 Stats 顶层的参数组合，并按 CNN 系统实际选择 Cache 与中断。

| 参数组 | 当前完整 CPU5 参考值 |
| --- | --- |
| 激活 CPU 与后端 | `SKELETON_ONLY=0`、`EXTERNAL_IMEM=1`、`EXTERNAL_DMEM=1` |
| 整数流水线 | `ENABLE_FORWARDING=1`、`ENABLE_CONTROL_FLOW=1`、`ENABLE_RAM=1` |
| 外设与机器态 | `ENABLE_MMIO=1`、`ENABLE_SYNC_TRAPS=1`、`ENABLE_CSR=1`、`ENABLE_FENCE=1` |
| 乘除法 | `ENABLE_M=1`、`ENABLE_RV32M=1` |
| 本地数据 RAM | `ENABLE_D0_BRAM=1`、`DMEM_WORDS=4096`、`DMEM_BASE_ADDR=32'h00010000` |
| 指令存储 | `IMEM_WORDS=8192`；外接同容量 `soc_instr_mem` |
| Cache | `ENABLE_ICACHE=1`、`ENABLE_DCACHE=1`；各 `SETS=64`、`LINE_WORDS=4` |
| 分支预测 | `ENABLE_BRANCH_PRED=1`、`BTB_ENTRIES=64`、`BRANCH_RESOLVE_IN_ID=0` |
| 串口 | `UART_CLOCK_HZ=50000000`、`UART_BAUD=115200`、`UART_RX_FIFO_DEPTH=16` |
| 机器设备 | `ENABLE_TIMER_DEVICE=1`、`ENABLE_SOFTWARE_DEVICE=1` |
| 中断源 | `ENABLE_EXTERNAL_IRQ=1`、`ENABLE_SOFTWARE_IRQ=1`、`ENABLE_TIMER_IRQ=1`；实际电平按新系统连接 |

参数名称以 RTL 声明为准。Cache 或 IRQ 的选择发生变化时，软件与 testbench 也要使用对应配置。`perf_cycle_events` 只是事件输出；保留原统计能力还需实例化和连接 Stats 单元。

## AXI4-Lite 连接合同

CPU 包装对外为 AXI4-Lite **主接口**；CNN 控制块为从接口。地址和数据均 32 位，单笔在途，没有 burst、ID 或多笔并发功能。

| 通道 | CPU 输出 | CNN/路由返回 CPU |
| --- | --- | --- |
| AW 写地址 | `m_axi_awaddr[31:0]`、`awprot[2:0]`、`awvalid` | `awready` |
| W 写数据 | `m_axi_wdata[31:0]`、`wstrb[3:0]`、`wvalid` | `wready` |
| B 写响应 | `m_axi_bready` | `bresp[1:0]`、`bvalid` |
| AR 读地址 | `m_axi_araddr[31:0]`、`arprot[2:0]`、`arvalid` | `arready` |
| R 读响应 | `m_axi_rready` | `rdata[31:0]`、`rresp[1:0]`、`rvalid` |

表中省略的名称前缀均为 `m_axi_`，完整 19 个端口见包装源码。CNN 从设备一侧通常命名为 `s_axi_*`，连线方向对应上表。

接线与实现要求：

1. AW 和 W 独立握手，可先到任意一个；分别锁存，配齐后只执行一次写入，再给 B 响应。
2. 所有 VALID 置位后，在对应 READY 接受前保持载荷稳定。B/R 同样需要保持，直到主机消费。
3. AXI 地址已按字对齐；写数据与 `WSTRB` 已按原字节地址共同移位，从设备不要再次移位。读响应返回完整 32 位字，CPU 完成字节/半字提取。
4. 桥仅将 `BRESP/RRESP=2'b00` 视为成功。非法偏移、只读寄存器写等情况应产生已约定的错误响应，避免静默挂起。
5. CPU、Cache、桥、路由和从设备使用协调复位。若加速器运算部分单独复位，AXI 接口仍需完成或清理在途事务。
6. 原系统只有一个时钟域。加速器若使用不同频率，需要明确 CDC 与复位方案；不能把原同步握手直接跨域相接。

详细现有语义见[CPU5 AXI 合同](../cpu5_axi_contract_20261024.md)与[D0 后端合同](../cpu5_d0_contract_20261025.md)。这些文件记录对应历史阶段，当前完整配置以板顶及本指南的入口为准。

## 地址与共享缓冲区

| 地址或范围 | 当前用途 | CNN 接入约束 |
| --- | --- | --- |
| `0x00000000–0x00007FFF` | 32 KiB 指令 ROM | 存放启动代码和程序 |
| `0x00010000–0x00013FFF` | 16 KiB D0 RAM | CPU 数据、常量、BSS与栈；当前无 CNN 第二访问端口 |
| `0x20000000–0x200000FF` | 本地 MMIO 页 | 已由 CPU 本地端点截获，不作为 CNN AXI 地址 |
| `0x20000010/14` | UART TX 数据/忙状态 | 识别结果输出可复用公共串口函数 |
| `0x20000018/1C` | UART RX 数据/状态 | 音频数据通道是否复用由双方决定 |
| `0x20000020–0x20000034` | GPIO | LED及按键 |
| `0x20000040–0x20000050` | mtime、mtimecmp、MSIP | 保留机器控制用途 |
| `0x30000000–0x300001FF` | 正式 CPU5 的 Stats | 保留该窗口；CNN 另选无重叠地址 |
| CNN 控制与数据窗口 | 尚未分配 | 确定基址、长度、路由和实际存储后再写入驱动 |

当前链接脚本把 `.rodata/.data/.bss` 和栈放在 D0 RAM，`__stack_top=0x00013FE0`，末字 `0x00013FFC` 供测试完成协议使用。不要从这 16 KiB 中随意划走权重或特征缓冲区。若更改容量或布局，需同步修改 RTL、链接脚本、初始化镜像和容量检查。

D Cache 只缓存配置的 RAM 范围，外设地址走旁路；写穿透仍不能解决加速器写 RAM 后的旧缓存行问题。当前没有 DMA Cache 一致性/失效接口，`FENCE` 也不执行 Cache 失效。

建议首次联调使用 **AXI 可访问、位于缓存 RAM 范围之外的独立 CNN 数据窗口**，由 CPU 读写该窗口。该窗口及实际 BRAM 需新建，当前系统没有自动提供。如果之后引入 DMA，必须先确定共享存储和仲裁，再定义所有权切换与一致性办法。

## 软件与寄存器约定

先共同确定以下字段，再编写 `cnn_mmio.h` 和驱动。此表是待约定的接口清单，尚无固定地址或位编码。

| 项目 | 需确定的语义 |
| --- | --- |
| 标识与版本 | 可读 ID、接口版本、复位值 |
| 启动与清除 | 启动触发方式，忙时再次启动如何处理，完成/错误怎样清除 |
| 状态 | busy、done、error，轮询时的稳定性 |
| 输入与输出 | 基址或窗口偏移、元素数、容量、对齐与读写方向 |
| 定点格式 | INT8 有无符号、排列顺序、scale/zero-point、累加位宽和饱和规则 |
| 模型与算子 | 层配置、权重布局、支持尺寸、池化/全连接的实际支持范围 |
| 中断 | 使能、挂起、清除、重新触发，IRQ 与 done 的关系 |
| 错误 | 越界、非法配置、忙时写入、响应码及软件超时处理 |

第一版软件流程：检查 ID → 写入配置与小输入 → 启动 → 带超时轮询状态 → 读取结果 → 与软件参考逐项比较 → UART 输出摘要。对 MMIO 使用 `volatile` 访问；带副作用的寄存器应规定唯一执行时刻，避免回压期间重复启动或重复弹出数据。

项目简介中的“CPU 负责 MFCC、加速器负责 CNN”可作为分工目标。MFCC 内存占用、定点实现和运算时间需另行评估；当前 CPU 板测没有证明这条音频链路已完成。

## 完成通知与中断

首次联调采用状态轮询最易定位问题。若接中断，在新顶层把 CNN IRQ 送入 `irq_external`，并启用机器态中断及 ISR。CPU 原始外部 IRQ 经两级同步，CNN 应保持电平直到 ISR 清除设备源；短脉冲需要另外的保持/同步设计。

正式 CoreMark 顶层目前把 `irq_external/irq_software/irq_timer` 原始输入接为 0；内部机器定时器与软件中断设备仍保留。外部 IRQ 的复杂逻辑有仿真覆盖，现有独立 CoreMark 板测不能替代 CNN 中断联调。

## 建议的联调顺序与分工

| 步骤 | 工作 | 可检查的结果 |
| --- | --- | --- |
| 1 | CNN 队友交付顶层端口、寄存器表和一组参考向量 | 输入、布局、量化参数和期望输出一致 |
| 2 | 双方接入新路由与只读 ID 寄存器 | CPU 能读 ID，地址无冲突，错误访问有响应 |
| 3 | 完成参数与小数据窗口读写 | 字节使能、顺序、边界与复位符合约定 |
| 4 | 运行一组小算子，CPU 轮询并读取结果 | 与同精度软件参考逐元素对比 |
| 5 | 运行目标 CNN；再加入 MFCC/音频输入 | 模型、输入、分类结果可复核 |
| 6 | 按需要扩展中断和 DMA | 完成通知、共享数据、错误与复位均闭合 |
| 7 | 重新实现完整系统并上板 | 50 MHz 时序、资源和真实端到端结果 |

CPU 侧提供五级核、现有接口、公共外设与测量方式；CNN 侧提供运算 RTL、模型/权重、量化说明和参考数据。系统顶层、地址表、驱动、缓冲区与完整板级验证由双方共同完成。网络推理对照使用相同模型、输入与精度，记录推理延迟、端到端延迟、准确率和资源。CoreMark 用于回归 CPU 基线。

## 文件与开发约定

- 新模块建议放 `rtl/cnn/`，驱动与示例放 `software/cnn/`，接口说明放 `docs/integration/`；按实际新增文件建立构建清单。
- 使用独立 `cnn-integration` 分支及新系统顶层；已有 `rtl/cpu5_*` 是处理器实现与包装，不按名称批量重命名。
- 固件修改后重建初始化镜像，硬件下载使用包含该镜像的同次位流。PDS 采用英文工程路径、SystemVerilog 模式及正确 include 路径。
- `build/`、ModelSim 工作库、临时波形保留在本地。需归档的原始证据按既有 `docs/evidence/**/raw_evidence.zip` LFS 规则单独保存。
- 早期验收脚本可能要求阶段源码身份或本机工具路径；出现阻塞先核对配置与依赖，保留原检查规则。
