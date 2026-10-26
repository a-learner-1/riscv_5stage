# CPU5 CoreMark 功能接入与测量窗口合同

日期：2026-10-25。基线：`6a39363a70440be7b2a3a064ddedf1b6196cc904`（S16 十类 Stats 系统验收）。
本文件只冻结本阶段的**接入范围、硬件身份、窗口语义与拒绝条件**；它不是成绩单，也不是时序或上板签核。

## 阶段目标与不做的事

本阶段把真实 RV32IM CoreMark（1 迭代、performance 种子、`TOTAL_DATA_SIZE=2000`）作为固件跑在
CPU5 schema4/profile2 系统上，并用同一套 Stats 端点取得测量窗口、十类互斥周期分类、I/D Cache 与
BTB 差分，再做三方可交叉核对：CPU 自读报告、测试平台独立账本、宿主独立审计。

不做：正式 10 秒 CoreMark 成绩、`CoreMark/MHz` 指标、CPU5 P&R/STA、LUT/APM/Fmax、bitstream、
上板测量、A01–A16 全部签署。1 迭代运行按上游规则**只能**用于功能 CRC 校验，不得打印或推断正式成绩。

## 平台身份（一个镜像只绑定一种硬件）

| 项 | 冻结值 | 说明 |
|---|---|---|
| Stats 基址 / ID | `0x30000000` / `0x434d4158` | 原 schema4 端点，未改动 |
| schema / profile | 4 / 2 | 十类 64 位、窗口 `0x200` |
| I/D Cache | 4 sets × 4 words，几何字 `0x02040010` | 开关成对，`cache_enable` 读回 0 或 3 |
| BTB | 16 项，配置字 `0x00100001` | 本阶段固定启用 |
| 数据后端 | AXI RAM 或 D0 片上 RAM，`backend_id` 0/1 | 由 Stats word `0x1c` 读回 |
| 时钟 / UART | 50 MHz / 5 MBaud | 每位 10 个时钟，仿真中每字符 100 周期 |
| mtime | 每个 `clk` 递增 1 | 与周期计数 1:1 |

固件在 `portable_init` 中读回 ID、开关字、几何字、BTB 配置字、schema 与后端字；任一不符即置
`coremark_failed`，并且**不得**继续产生 PASS 报告。其中后端字必须**无条件双向核对**：同一个镜像会被
装入实际接上的后端，若只在 D0 镜像里检查，"AXI 镜像 + D0 硬件"这类错配就会漏过。观测到的后端字
随报告输出（`COREMARK backend_id=`），由测试平台与宿主审计各再核一次。
旧的 schema3/profile1 AXI CoreMark 头必须拒绝本阶段生成的配置；本阶段的 CPU5 头也必须拒绝旧的
schema3 配置（双向 guard）。

## 测量窗口语义

- `start_time()`：先读 Stats word `0x00`（在同一 AXI 读边沿冻结全部 16 个普通字、5 个 I-Cache、
  7 个 D-Cache 与 7 个 BTB 计数，以及十类 64 位 START 快照），**再**读 mtime。
- `stop_time()`：先读 mtime，**再**读 Stats word `0x04`（同边沿冻结 STOP 快照）。
- 因此 mtime 区间严格位于统计区间内部：`0 < raw_ticks ≤ cycle_delta`，且
  `gap = cycle_delta − raw_ticks` 只包含两次 Local-MMIO 标记与相干 64 位 mtime 读取的开销。
  本阶段接受条件为 `gap ≤ 256`；它必须被记录而不是隐藏。
- 窗口接受条件：`cycle_delta>0`、`cycle_delta<2^32`、`instret_delta>0`；十类差分逐类
  `≤ cycle_delta`，其和 `== cycle_delta`。任一条不满足即整份报告作废（`counter_valid=0`），
  不得跟随 PASS。
- 窗口内的 Cache/BTB 差分用 START/STOP 冻结bank 相减，窗口必须 `<2^32` 周期以容忍一次低字回卷。

## 验证分级

1. **RTL 结构不变量（每个周期）**：`cycle_count` 与独立周期计数器一致；`instret_count` 与
   `retire_fire` 计数一致；退休序号严格递增；不得出现 trap/imem_fault/dmem_fault；
   `perf_cycle_events` 每周期恰一位（首周期为零）。
2. **窗口三方核对**：测试平台用 CPU5 事件引脚自行累加十类账本与在触发边沿采样的
   `cycle_count/instret_count`；两端必须与冻结快照 bank 相减、与固件 UART 报告逐字一致。
3. **观测通道核对**：MMIO 发送边沿捕获的控制台字节流必须与真实 `uart_tx` 引脚按 8N1 解码出的
   字节流**逐字节**相同，且帧数相等、数据位与停止位零错。`tohost` 必须是唯一一次整字非零写，
   并绑定到**该条指令自己**的 owner completion、退休与写回：`completions=1`、`retired=1`、
   退休周期不早于完成周期、`writebacks >= 退休序号+1`，物理 RAM 字等于 1。
4. **CoreMark 功能核对**：performance 种子冻结 CRC
   `seedcrc=0xe9f5 / crclist=0xe714 / crcmatrix=0x1fd7 / crcstate=0x8e3a`；
   必须出现 `COREMARK RESULT: SMOKE PASS` 与上游 `ERROR! Must execute for at least 10 secs`，
   不得出现 `ERROR:`、`Cannot validate operation`、`COREMARK RESULT: FORMAL` 或 `SMOKE FAIL`。
5. **不可能值拒绝**：`retired > compute_cycles`、`window > compute_cycles`、
   `window_retired > retired`、写回领先退休、`cycle_delta >= 2^32`、`raw_ticks > cycle_delta`
   等一律判失败——这些值在物理上不可能，必须由审计器主动拒绝，而不是"看着很大就放过"。
6. **负证据**：对控制台与快照记录做单点变异（改一类差分、改窗口、改 CRC、把 valid 置 0、
   删除结果行、注入错误行、伪造 FORMAL 声明、改触发计数、改控制台字节数、把退休数改成不可能值、
   改后端身份等），同一个审计器必须全部拒绝；接受任一变异即视为检查未接线。

## 覆盖矩阵（本阶段覆盖 / 未覆盖）

| 维度 | 本阶段覆盖 | 未覆盖 |
|---|---|---|
| CoreMark 种子 | performance（`PERFORMANCE_RUN=1`、`TOTAL_DATA_SIZE=2000`、`ITERATIONS=1`） | validation 种子（`0x18f2` 组）、`TOTAL_DATA_SIZE=6000` |
| 迭代数 | 1 次（功能核对） | 自动校准、≥10 秒正式测量、UART 回读成绩 |
| 数据后端 | AXI RAM、D0 片上 RAM（两值都覆盖，且双向硬检） | —— |
| I/D Cache | 关闭；4 sets × 4 words（每级 64 B，成对开关） | 常规容量（2 KiB 级）、其他相联度/行宽、I/D 非对称 |
| 分支预测 | 恒开，BTB 16 项 | BP 关闭、其他 BTB 条目数、预测质量架构级验证 |
| 分支解析位置 | 恒为 `BRANCH_RESOLVE_IN_ID=0` | ID/EX 解析对照 |
| 存储等待 | 全 0（IMEM/D0/AXI） | 非零等待矩阵 |
| ISA | rv32im | rv32i |
| 时钟 / UART | 50 MHz / 5 MBaud | 其他波特率、真实 UART 回读的正式成绩 |

表中的空洞是本阶段的**已知范围边界**，不得用本阶段结果外推。特别地：加 Cache 后窗口变长是
「4 sets × 4 words 几何 + AXI 回填成本」的观测值，不是 Cache 的普适结论，也**不作为任何断言的
通过条件**（脚本只记录该观测）。

## 范围边界

新增 `software/cpu5_coremark/`（端口头、`core_portme_cpu5.c`、`start.S`、`link.ld`）、
`tools/build_cpu5_coremark_images.py`、`tb/cpu5_coremark_tb.v`、`tools/run_cpu5_coremark.py`、
`tools/verify_cpu5_coremark.py`、`tools/freeze_cpu5_coremark.py` 与 `run_cpu5_coremark.do`。
RTL 不新增文件：本阶段复用未改动的 `cpu5_stats_axi_lite_top` 及其组合的系统顶层、
共享的 `core_portme.c`、`mmio.h`、`timer.h` 与 `benchmarks/coremark/` 源码。

固件镜像固定 ROM 32 KiB @`0x00000000`、RAM 16 KiB @`0x00010000`，栈顶 `0x13ffc` 之前保留
`tohost` 字；`.rodata` 与 `.data` 合并为单份 RAM 初始化镜像，与三级产品相同的双镜像流程。

原三级产品、原 AXI CoreMark 端口、十类 Stats 端点与正式发布包在本阶段**不被修改**。
