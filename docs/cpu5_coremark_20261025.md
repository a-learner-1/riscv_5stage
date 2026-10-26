# CPU5 CoreMark 功能接入与十类窗口系统验收

日期：2026-10-25。基线：`6a39363a70440be7b2a3a064ddedf1b6196cc904`（S16 十类 Stats 系统验收）。
状态：**PARTIAL VERIFIED：CPU5 CoreMark 功能 + schema4 窗口/Cache/BTB 四配置系统验证**。

本阶段把真实 RV32IM CoreMark（1 迭代、performance 种子、`TOTAL_DATA_SIZE=2000`）作为固件跑在
CPU5 schema4/profile2 系统上，四个冻结配置（AXI/D0 数据后端 × I/D Cache 开/关）全部通过功能
CRC、十类互斥窗口、Cache/BTB 差分与 UART 引脚级通道核对。**RTL 未改动**。原三级产品、原 AXI
CoreMark 端口、十类 Stats 端点与正式发布包保持原样。

## 实现

- `software/cpu5_coremark/core_portme_cpu5.c` 在同一编译单元内复用未修改的 `core_portme.c`，
  只包裹计时边界与 schema4 平台报告，使计时、格式化、CRC 判定和正式成绩规则不跨平台分叉。
- `coremark_cpu5_stats.h` 冻结硬件身份：ID、Cache 开关字、几何字 `0x02040010`、BTB 配置字
  `0x00100001`、schema 4、后端字。任一不符即置 `coremark_failed`，报告不得跟随 PASS。旧的
  schema3/profile1 AXI 头与本阶段 CPU5 头双向互斥。
- 窗口语义：`start_time()` 先读 Stats word `0x00`（同边沿冻结 16 普通字 + 5 I-Cache + 7 D-Cache +
  7 BTB 与十类 64 位 START 快照）**再**读 mtime；`stop_time()` 先读 mtime **再**读 word `0x04`。
  因此 mtime 区间严格内含于统计区间，`gap = cycle_delta − raw_ticks` 必须为正且有界（本阶段
  上限 256 周期）。实测 gap 为 52/84/120/148，对应四个配置各自的 Local-MMIO 标记与相干读取开销。
- 折叠身份探针：`portable_init` 只读一次 word `0x00`，使整次运行恰好留下 START=2（探针 +
  `start_time`）、STOP=1（`stop_time`）的触发闭包。
- **后端身份双向硬检**：`portable_init` 无条件读 Stats word `0x1c` 并与镜像自身后端身份比较。
  只检 D0 方向会让"AXI 镜像跑在 D0 硬件上"照样通过（同一个镜像会被装入实际接上的后端），
  因此两个方向都必须失败；报告的 `COREMARK backend_id=<观测值>` 由测试平台与宿主审计再各查一遍。
- **完成协议绑定到指令本身**：终态 `tohost` 必须由唯一一次整字非零写产生，并沿 owner 暴露的
  `req_owner_pc/instr` 追到**该条指令自己**的 completion、退休与写回（`writebacks >= 退休序号+1`），
  不再只看计数器差值。
- `tb/cpu5_coremark_tb.v` 在一次 ModelSim 进程内并行跑四个配置（`CASES` 参数可降到 1 做单配置
  切片调试）。每周期检查周期/退休计数一致、退休序号严格递增、十类事件每拍 one-hot、无
  trap/imem_fault/dmem_fault；并自行从 CPU5 事件引脚累加十类账本、在触发边沿采样
  `cycle_count/instret_count`，与冻结快照 bank、与固件 UART 报告三方核对。
- 观测通道：控制台字节取自 CPU5 Local-MMIO 发送边沿，同时按 8N1、10 周期/位解码真实 `uart_tx`
  引脚，逐字节比对两条流并要求数据位 0 错、停止位 0 错。完成信号必须是唯一一次整字非零
  `tohost` 写并获得成功响应，物理 RAM 字等于 1。
- 工具：`tools/build_cpu5_coremark_images.py`（四镜像，0 warning/0 error，逐字校验 RV32IM 文本）、
  `tools/run_cpu5_coremark.py`（编译 + 仿真 + 源文件不可变守卫 + 宿主审计）、
  `tools/verify_cpu5_coremark.py`（独立审计 + 22 项负证据 + 跨配置守恒）、
  `tools/freeze_cpu5_coremark.py`（证据包），入口 `run_cpu5_coremark.do`。

## 本阶段新运行

运行 `20261026T033442697661Z_0dfe0c9a`（评审修正后的回归重跑）：一次 ModelSim 进程内四个配置，
编译 0 Warning/0 Error，被测源文件在运行前后 SHA 不变。

| 配置 | 窗口周期 | 窗口退休 | CPI | mtime ticks | 窗口−ticks | UART 字节=引脚帧 |
|---|---|---|---|---|---|---|
| case0 AXI / 无 Cache | 661985 | 289747 | 2.284700 | 661901 | 84 | 3747 = 3747 |
| case1 AXI / I+D Cache | 1235984 | 289747 | 4.265735 | 1235820 | 164 | 3797 = 3797 |
| case2 D0 / 无 Cache | 386441 | 289747 | 1.333719 | 386389 | 52 | 3749 = 3749 |
| case3 D0 / I+D Cache | 845286 | 289747 | 2.917324 | 845166 | 120 | 3794 = 3794 |

> 周期数是**观测值**：脚本只记录它们（`verification.json` 的 `observations` 段），不断言
> 「Cache 必然更慢」或「D0 必然更快」——否则将来一次真实优化会让验收误报失败。
> 带 Cache 的两配置在加入后端身份硬检后窗口略有变化（代码布局位移改变了 Cache 命中行为），
> 无 Cache 的两配置不变，可据此确认窗口不受该改动本身影响。

十类互斥周期（每配置差分之和均等于该配置窗口差分）：

| 类 | AXI/无Cache | AXI/Cache | D0/无Cache | D0/Cache |
|---|---|---|---|---|
| work_other | 302117 | 301443 | 302117 | 301449 |
| ifetch_wait | 0 | 193895 | 0 | 202149 |
| data_read_wait | 233924 | 518718 | 15104 | 172910 |
| data_write_wait | 73004 | 86899 | 16280 | 29706 |
| local_mmio_wait | 12 | 12 | 12 | 12 |
| redirect_wait | 24740 | 106829 | 24740 | 110872 |
| mul_wait | 28188 | 28188 | 28188 | 28188 |
| div_wait | 0 | 0 | 0 | 0 |
| load_use_wait | 0 | 0 | 0 | 0 |
| id_hazard_wait | 0 | 0 | 0 | 0 |

Cache/BTB 窗口差分（START/STOP 冻结bank 相减）：

| 配置 | I: access/hit/miss/refill/err | D: access/hit/miss/refill/err/write/bypass | BTB: lookup/hit/taken/resolved/mismatch/dir/tgt |
|---|---|---|---|
| case0、case2 | 全 0（Cache 关闭时 bank 与差分都为 0） | 全 0 | 314487/46904/28569/57268/12370/8728/0 |
| case1 | 313174/273260/39914/159653/0 | 68887/33092/21613/86452/0/14181/1 | 313174/46873/28541/57268/12370/8728/0 |
| case3 | 312323/272919/39404/157613/0 | 68887/33092/21613/86452/0/14181/1 | 312323/46867/28567/57268/12370/8728/0 |

跨配置守恒（由记录工件独立推导，非固件或测试平台声明）：

- 四个配置**窗口内**退休数完全相同：**289747**（同一份编译镜像族，同一指令流；整程序退休数随
  配置不同，不得混用）。
- 纯 CPU 内部类不随存储配置变化：`mul_wait=28188`、`local_mmio_wait=12`。
- 已提交控制流不变：`bp_resolved=57268`、`bp_next_pc_mismatch=12370`、`bp_direction_error=8728`
  四配置一致；只有取指侧 lookup/hit/taken 随 Cache 配置移动。
- `work_other` 最大最小差 674 周期（≈0.22%），是 Cache 配置重归因造成的抖动。
- 两个 Cache 配置的 D-Cache 访问流完全相同（access 68887、hit 33092、miss 21613、
  refill 86452、write 14181、bypass 1），说明窗口差异来自取指与命中时序而非数据流本身。
- D0 相对 AXI 的窗口节省（**观测**）：无 Cache 275544 周期，有 Cache 390698 周期；
  Cache 相对无 Cache 的窗口代价（**观测**）：AXI 573999 周期，D0 458845 周期。

功能核对：四配置 UART 报告均含 `COREMARK RESULT: SMOKE PASS`，上游 performance 种子
CRC 全部命中 `seedcrc=0xe9f5 / crclist=0xe714 / crcmatrix=0x1fd7 / crcstate=0x8e3a`，并保留上游
`ERROR! Must execute for at least 10 secs` 与 `NOTE: smoke timing is a functional observation; it is
not a formal score.`；不得出现 `ERROR:`、`Cannot validate operation`、`COREMARK RESULT: FORMAL`
或 `SMOKE FAIL`。编译镜像：text 27724/27728/27720/27724 字节（ROM 32768），data 5568（四配置相同），
bss 2296，栈余量 8488 字节（下限 2048）。

终态 `tohost` 绑定（每个配置都核过）：`requests=1 / responses=1 / completions=1 / retired=1`，
退休周期不早于完成周期，且 `writebacks ≥ 退休序号+1`（即该条 STORE 自己的写回已发生）。
后端身份：报告输出观测到的 `COREMARK backend_id=`（AXI 为 0、D0 为 1），与镜像身份双向一致。

负证据与审计（`tools/verify_cpu5_coremark.py`）：控制台自洽性（十类之和 = 自身窗口、tick gap =
自身差值）与快照交叉核对（窗口、十类、Cache、BTB 逐字段）全部通过；**22 项单点变异全部被同一
审计器拒绝**——改一类差分、改窗口周期、把 `counter_valid`/`cycle_profile_valid` 置 0、改
seedcrc/crclist、改 icache/bp 差分、把 stats_schema 改成 3、翻转 cache 开关、改 tick gap、
改十类和、删除结果行、注入 `ERROR:` 行、伪造 `COREMARK RESULT: FORMAL`、改触发计数、
改控制台字节数、改快照 bank、翻转 case 身份、把退休数改成不可能值、改后端身份。
接受任一变异即视为检查未接线。

## 覆盖矩阵与范围边界

| 维度 | 本阶段覆盖 | 未覆盖 |
|---|---|---|
| CoreMark 种子 | performance（`TOTAL_DATA_SIZE=2000`、`ITERATIONS=1`） | validation 种子、`TOTAL_DATA_SIZE=6000` |
| 迭代数 | 1 次（功能核对） | 自动校准、≥10 秒正式测量、UART 回读成绩 |
| 数据后端 | AXI RAM、D0 片上 RAM（两值都覆盖 + 双向硬检） | —— |
| I/D Cache | 关闭；4 sets × 4 words（每级 64 B，成对开关） | 常规容量（2 KiB 级）、其他相联度/行宽、I/D 非对称 |
| 分支预测 | 恒开、BTB 16 项 | BP 关闭、其他条目数、预测质量架构级验证 |
| 分支解析位置 | 恒为 `BRANCH_RESOLVE_IN_ID=0` | ID/EX 解析对照 |
| 存储等待 | 全 0 | 非零 IMEM/D0/AXI 等待矩阵 |
| ISA | rv32im | rv32i |
| 时钟 / UART | 50 MHz / 5 MBaud | 其他波特率、真实 UART 回读成绩 |

表中的空洞是本阶段的已知边界，不得用本阶段结果外推。

## 本轮评审修正（4 项，均已实跑复验）

1. **后端身份双向硬检**：原先只在 D0 镜像里读 Stats word `0x1c`，AXI 镜像跑在 D0 硬件上仍可能通过。
   现改为无条件读取并与镜像身份比较，两个方向都会失败；报告的 `COREMARK backend_id=` 由测试平台
   与宿主审计各再核一次。
2. **验收假通过漏洞**：新增「退休数不得超过总周期预算」「窗口退休不得超过整程序退休」
   「`window <= compute_cycles`」等不可能值拒绝；终态 `tohost` 改为绑定到**该条指令自己**的
   owner completion、退休与写回（`writebacks >= retire_index+1`），不再只看计数差；`verify` 的
   `--cases 0` 空选择直接报错，不再可能给出空集 PASS。
3. **去掉把性能现象写成正确性要求**：删除「Cache 开启必须更慢」「D0 必须更快」的断言，改为
   `observations` 记录；保留的只有结构性守恒（同一镜像族窗口退休数相同、纯 CPU 内部类不变、
   已提交分支量不变、Cache 配置的 D-Cache 访问流相同）。
4. **证据包补全原始工件**：除 `build.json` 外，新增每个配置的 `coremark_build_config.h`、
   `program.elf`、`program_text.bin`、`program_data.bin`、`program.hex`、`program_data.hex`、
   `program.map`、`program.lst`，以及本次仿真的 `compile.do`/`simulate.do`。

## 关键事实与边界

- `ifetch_wait=0` 不是漏计：本平台取指端点零等待，只有启用 I-Cache 后未命中才产生取指等待
  （194058 / 200617）。
- `div_wait`、`load_use_wait`、`id_hazard_wait` 在本工作负载窗口内为 0：CoreMark 测量窗口内不执行
  DIV；前递与 D-owner 已把访存等待归入 data_read/data_write 类。十类非零覆盖由 S16 定向套件
  单独承担，本阶段不据此声称任何类别的漏计或覆盖。
- **本阶段没有任何成绩结论**：1 迭代 CoreMark 按上游规则只能做功能核对，
  `COREMARK coremark_per_mhz` 是本次仿真时间换算的功能性观测值，不得当作性能指标引用。
- 未运行：正式 10 秒双种子 CoreMark 成绩与 UART 回读、CPU5@50 MHz 同频 A/B、P&R/STA、
  LUT/APM/Fmax、bitstream、上板测量、A01–A16 全部签署。功能仿真的 50 MHz 时钟不是时序收敛证明。

## 源码与证据

- [范围合同](cpu5_coremark_contract_20261025.md)、[证据目录](evidence/cpu5_coremark_20261025/README.md)
- 新增：`software/cpu5_coremark/`（`coremark_cpu5_stats.h`、`core_portme_cpu5.c`、`start.S`、`link.ld`）、
  `tb/cpu5_coremark_tb.v`、`tools/build_cpu5_coremark_images.py`、`tools/run_cpu5_coremark.py`、
  `tools/verify_cpu5_coremark.py`、`tools/freeze_cpu5_coremark.py`、`run_cpu5_coremark.do`。
- 未修改：`rtl/` 全部文件、`benchmarks/coremark/`、`software/coremark_port/`、`software/mmio.h`、
  `software/timer.h`、原三级回归清单。

复现：

```powershell
python -B tools/build_cpu5_coremark_images.py      # 四个冻结镜像
python -B tools/run_cpu5_coremark.py               # 编译 + 四配置仿真 + 宿主审计
python -B tools/run_cpu5_coremark.py --cases 2     # 只跑前两个配置（切片调试）
python -B tools/verify_cpu5_coremark.py            # 独立审计 + 22 项负证据 + 跨配置守恒
python -B tools/freeze_cpu5_coremark.py            # 冻结证据包
```

需要 ModelSim 10.6e 与 xPack RISC-V GCC 15.2.0；工具默认路径记录在 `source_identity.json`。
本次的 64 份被测源码做了两级锚定：当前工作树字节仍等于运行时记录的 SHA256，且其**规范 LF**
字节等于本地提交里的 blob（仓库旧文件工作树为 CRLF、Git 存 LF，这是本仓库既有约定）。

## 后续门槛

1. CPU5 CoreMark **正式测量固件**：自动校准迭代数、≥10 秒测量、UART 回读 `CoreMark 1.0` 成绩行，
   并与十类窗口、Cache/BTB 差分一起入账（本阶段只做功能与窗口）。
2. CPU5 **BTB 架构级**接入与取指侧预测质量验证（本阶段 BTB 仅作为已存在的取指端点现象被观测）。
3. CPU5@50 MHz 同频 A/B、P&R/STA、LUT/APM/Fmax、bitstream 准备。
4. 双种子正式板测与 A01–A16 全量签署。
