# CPU5 微架构实现规格（RV32IM 五级流水线）

> **版本**：v0.3 / 2026-10-21 / 实现前合同修订，**不是已实现或已验证 RTL**  
> **基于工程**：`riscv_3stage-main (4).zip`；文档 `docs/rv32m_execution_20261021.md` 中的 `75c43aabb0581ec303664e0f51b48c387e1962db` 仅标记为 **RV32M 实现工作的起始代码基线**，不得充当已验收 RV32IM 提交。  
> **交付目标**：让 Codex 按可审查的小补丁实现五级 CPU；任何阶段不能修改旧 `rtl/cpu_top.v` 的行为或覆盖三级正式位流。  
> **标记约定**：`[现有]` 代表上传工程中真实存在的 RTL 信号；`[新增]` 为 CPU5 规格定义、尚未写入代码的信号；`[待实测]` 不能作为已证实事实。
> **v0.2 保留**：十类互斥周期归因、动态分支 RAW 测量、观测接口语义兼容、优先复用 `if_stage.v`、profiler 文件核对。  
> **v0.3 必要修订**：① D 端口 **年长请求优先 + STORE/LOAD 顺序**；② M 运算 **owner/killed/drain**；③ 冻结提交的三个 Git 角色分离；④ 唯一 IRQ/retire 真值表；⑤ Fetch epoch 与指令/D owner 年龄解耦；⑥ D2 静态依赖距离与就绪气泡分层；⑦ 设计/阶段/最终三种 PASS 门分离；⑧ CPU5@50 MHz 同频 A/B 先于提频签核。

## 0. 设计边界与已知事实

### 0.1 基线口径

- 三级 RV32IM：performance 117.958048697 CoreMark，50 MHz，2.359160974 CoreMark/MHz，CPI 1.463126049；资源 8,643 routed LUT、7,031 FF、4 APM、36 DRM。
- 最终 STA：Slow Setup WNS `+1.269 ns`、Fast Setup WNS `+6.810 ns`；使用 20 ns 时钟要求推算的等效周期为约 18.731 ns，**不等于**五级已验证的最高频率。
- 50 MHz 之外的 PLL 频档、五级 80/90/100 MHz、CPI 1.349 和 256 CoreMark 都是**待实现/待实测目标**。
- 旧硬件和板级项目基线必须保留：Git tag、正式 performance/validation 两份 `.sbit`、完整 UART、PDS 最终报告、固件、依赖与 SHA-256 manifest。上传的 ZIP 不包含可直接替代上述归档的全部来源。
- **提交角色必须分开**：`75c43a...` 是 `docs/rv32m_execution_20261021.md` 明文记录的 **M 工作起点**；根据本轮外部 Git 核对反馈，**已验收 RV32IM 源码提交候选**为 `347982c`，**板测证据提交候选**为 `ab8e3f6`。ZIP 无 `.git`，本次不能在本机验真这两个短 SHA。阶段 0 用原仓库执行 `git cat-file -t 347982c`、`git cat-file -t ab8e3f6`、`git show -s --format=fuller <SHA>`、`git rev-parse <SHA>^{commit}` 并对照位流 manifest 与文件散列；核验后记录**完整 40 位 SHA**，才允许打冻结 tag。不可把文档中的“代码基线”解释为已完成交付的 commit。
- CoreMark/LUT 基线：`117.958048697 / 8.643 = 13.647... CoreMark/kLUT`，报告可记为 **13.65 CoreMark/kLUT**。

### 0.2 本规格不容误解的三点

1. `work_other - instret` 为 `56,376,000/2000 = 28,188` 拍/迭代（由正式 UART 原始值核算），**不能全部认定为 MUL，更不能以 28,188/4,400 推断单次乘法要 6.4 拍**。RV32M 同时有乘法和逐位除法/求余；需新计数器拆分。
2. `rtl/data_cache.v` 的 **Cache 命中入口**允许 `RESPONSE && rsp_ready` 时接受下一请求（理论 hit II=1）；这不证明当前 **CPU+Cache+D0 路由全链** II=1。三级 CPU `req_sent/mem_active` 和 D0 后端 `dmem_region_router.active` 仍会影响发起吞吐。
3. `[新增]` EX 发起的 RAM LOAD 是**可能投机的纯读**，即使只提前一个流水级，也可能遇到年长指令异常/中断。读事务被冲刷后必须排空并忽略响应；STORE、MMIO 读/写绝不能这样做。
4. **纯读不代表可越过年长 STORE**：只要年长 MEM 仍有未完成的 STORE、MMIO/Stats/未知 AXI 事务或可能改变读可见性的内存操作，年轻 EX RAM LOAD 即使属于白名单也不得 `req_fire`。必须维护程序内存顺序，不能产生 `SW [A]; LW [A]` 读旧值的情况。D 端请求仲裁首先按动态指令年龄，然后才区分副作用种类。
5. `rv32m_unit.v` 没有 kill/cancel 接口；其 `done` 保持到下一次合法 `start` 或 reset。因此 CPU5 必须实现 **M 单元占用/owner/killed/drain** 合同；清流水 `valid` 绝不等于取消已启动的 M 计算。
6. **Fetch epoch 是前端请求代际标记，不是全流水存活判据**。年轻 ID 分支改变 fetch epoch 时，不能杀死其年龄更老的 EX RAM LOAD。流水指令和 D 事务是否活着只能按 `seq_id`/年龄、专用 `killed` 和事件源判定。

### 0.3 代码定位（现有事实）

| 文件 / 源码区域 | 已存在合同 | 对 CPU5 的影响 |
|---|---|---|
| `rtl/cpu_top.v` 开头的端口与参数 | `pc_x/instr_x/valid_x`, `wb_*`, `retire_valid`, `perf_cycle_events[5:0]`, 独立 I/D 请求响应 | 对外兼容端口；五级内部不沿用旧 `stall_x` 语义 |
| `rtl/cpu_top.v` 约 730–780 行 | `forward_rs1_x/forward_rs2_x`：WB→EX | 五级增加 EX/MEM、MEM/WB→EX/ID 相关及优先级 |
| `rtl/cpu_top.v` 约 790–1050 行 | `bp_resolve_valid`、Trap/IRQ/CSR、`arch_next_pc`、RV32M 控制 | 必须迁至有年龄保证的提交/控制逻辑 |
| `rtl/cpu_top.v` 约 1230–1460 行 | `mem_start_x`, `mem_active`, `req_sent`, `mem_req_fire`, `mem_rsp_success`, `mmio_endpoint_pending` | 事务独占、描述符稳定、单次副作用、响应归属 |
| `rtl/cpu_top.v` 末尾 | `retire_to_wb`, `instret_count`, `perf_cycle_events[5:0]` | 重新定义 MEM 退休事件及 CPU5 十分类，保留原六分类的历史 ABI 和快照时序 |
| `rtl/data_cache.v` 约 62–75、125–180 行 | `req_ready=IDLE || (RESPONSE && rsp_ready)`；RAM hit 同步读；Miss/写单事务 | 只在响应正常消费且全链允许时可能实现连续 hit 请求 |
| `rtl/data_bus_adapter.v` 约 31–75 行 | `pending` 期间不再接受请求，最早接受后下一拍响应 | 本地非 Cache 端口 II 可能大于 1 |
| `rtl/dmem_region_router.v` 约 31–68 行 | `active` 期间上游 `req_ready=0`，完成响应后下一拍才受理 | D0 的 Miss/写后端并非同拍交接 |
| `rtl/if_stage.v` 约 43–60、131–260 行 | `fetch_pending_q`, `req_hold_q`, `fetch_stale_q`, `imem_fault`，且 `pc_x/instr_x/valid_x` 等为同步寄存输出 | **优先原样复用并做五级包装**；必须验证停顿/flush/粘滞故障交接，不能仅因输出是寄存器就断言直接适用 |
| `rtl/soc_axi_lite_top.v` 约 165–225 行 | `data_cache` → D0 路由 → BRAM/AXI；非 RAM 去 AXI | 投机读只准明确范围内的普通 RAM |
| `rtl/soc_coremark_axi_top.v` 约 100–105 行 | RAM `DMEM_BASE_ADDR..+DMEM_WORDS*4`；stats `0x30000000/0x200` | Stats START/STOP 读有快照副作用，不可在 EX 发起 |
| `rtl/rv32m_unit.v` 全部 | `start/busy/done/result`；乘法两处理态；除法 32 迭代 | 非定长 M 操作；启动和完成只能各一次 |
| `rtl/axi_lite_coremark_stats.v` 约 60–76、125–260 行 | 六种 64 位寄存计数；START `0x100..0x12c`、STOP `0x140..0x16c` | CPU5 十分类必须升级统计从设备/固件/schema；不能从 START `0x130` 顺序追加第三个新增类而碰撞 STOP |

## 1. 体系结构总规则

- 五级：`IF → ID → EX → MEM → WB`，**单发射、顺序执行、顺序退休**；不使用 ROB，不引入非阻塞多未决 LOAD。
- 每条动态指令采用一个 `valid` 与（仿真可选）单调 `seq_id`。冲刷仅使**年轻于冲刷源**的指令失效，不能取消已提交的旧指令。
- **MEM 是唯一架构退休裁决点**：在 MEM 依据同步异常、访存响应、CSR/MRET、IRQ、前序副作用完成情况决定是否退休；WB 只是对已退休且需要写 GPR 的指令写回。因此 `retire_valid` 不得直接等同于 `wb_we`。**IRQ 与普通退休不允许在同一边沿同时发火**；IRQ 使用 §5 的唯一边界规则，在连续 ALU 流也须有界响应。
- **MEM/WB 写回较晚**时，EX 和 ID 必须能从 MEM/WB 前递；WB 的旧值仍可在年轻 Trap 当拍正常写入。`x0` 永远不写。
- CSR 写、MRET、Trap 状态更新、BP 训练、架构 `arch_next_pc` 更新都必须按正确年龄执行，每条指令至多一次。CPU 周期/Cache/BP 的调试观测与 ISA 架构效应分离。
- 参数化保留旧开关：`ENABLE_M`, `ENABLE_TRAPS`, `ENABLE_TIMER_IRQ`, `ENABLE_EXTERNAL_IRQ`, `ENABLE_SOFTWARE_IRQ`, `ENABLE_BRANCH_PRED`, `BTB_ENTRIES`；关闭扩展的非法编码仍产生精确异常（Trap 环境启用时）。
- 无 C 扩展，`IALIGN=32`；JALR 清 bit0，再检查 PC[1:0]。无 PMP、U/S mode、DMA/Cache coherence 等新功能。
- `[新增] BRANCH_RESOLVE_IN_ID` 可作为 A/B 构建参数；**最终默认值由阶段 0.5-D 的动态 RAW 测量与阶段 5 的实际 STA/IPC 决定**。在测量前只允许写独立可切换逻辑，不把 ID+插泡当成长期唯一实现；不能假定每次重定向恒定多一拍。

### 1.1 建议的独立文件布局与前端复用策略

```text
rtl/cpu5_top.v               # 新核：尽量保留对外功能端口，内部五级
rtl/if_stage.v               # 旧版原封不动，优先作为 CPU5 的前端候选
rtl/cpu5_if_adapter.v        # [按需] 复用前端的 valid/ready/flush/故障适配
rtl/if_stage5.v              # [有条件] 只有复用验收失败且包装无法修复时新建
rtl/cpu5_hazard.v            # 相关检测与前递选择
rtl/cpu5_mem_ctrl.v          # 事务所有权、req/rsp 接受及权限
rtl/cpu5_commit_ctrl.v       # MEM 提交、Trap/CSR/IRQ/MRET 仲裁
rtl/cpu5_m_owner.v           # 新包装/控制：M owner、killed、drain；原 rv32m_unit.v 不改
rtl/cpu5_cycle_profile.v     # 十类周期主归因和独立事件诊断
rtl/axi_lite_coremark_stats5.v # CPU5 独立十分类快照版本
rtl/soc_axi_lite_cpu5_top.v  # CPU5 独立 SoC 变体
# 原 rtl/cpu_top.v、rtl/if_stage.v、旧统计模块和三级板顶均不修改
```

**现有 `if_stage.v` 的正确复用边界**：其 `pc_x/instr_x/valid_x/predicted_next_pc_x/prediction_taken_x/prediction_hit_x` 为同拍寄存的响应输出，可以候选映射到 CPU5 的 IF/ID。`stall_x` 可候选映射到 `ifid_hold`，`redirect_x/redirect_pc_x` 可由 CPU5 统一仲裁驱动，`bp_update_*` 可改由安全的 MEM 提交驱动。这只是**接口假设，不是等价性证明**。

复用必须先覆盖：① ID 阶段被阻塞、I 响应到来时数据不丢；② `redirect_x && stall_x` 同拍时，不会清掉尚未成功转移到 ID/EX 的指令；③ 旧在途请求、`req_hold_q/fetch_stale_q` 丢弃响应时，更新 PC/预测元数据无错；④ `imem_fault` 是**粘滞侧带状态**，不是与 `valid_x` 一起提交的独立 IF/ID 异常包，须经包装/仲裁确保不抢老指令异常；⑤ BTB MEM 更新后无重复训练；⑥ I 端长期背压时 valid/addr 稳定；⑦ 同拍旧响应与新请求接受。

**观测兼容只要求语义兼容，不要求旧内部探针同名**：`cpu5_top.pc_x/instr_x/valid_x` 若保持，应继续描述 **EX 阶段**的指令；`u_if_stage.pc_x/instr_x/valid_x` 被复用时实际对应 CPU5 **IF/ID**。不能因为两者旧版曾直连，就将它们在 CPU5 再绑为同一个信号。`retire_valid/wb_*/trap_*/dmem_*/imem_*/bp_*` 等对外功能接口尽量保留名称、宽度和**时间/年龄口径说明**。`perf_cycle_events` 是 schema 相关接口，CPU5 不承诺与旧 `[5:0]` 端口二进制兼容；必须在新 variant 中明确使用新宽度、schema 校验，不许隐式位宽截断。

**禁止危险伪兼容**：旧 `[现有] mem_start_x` (`cpu_top.v:1249`) 表示 **EX 阶段新访存开始/呈现条件**，不是 `mem_req_fire`；旧 D1/M1 的 `mem_start_x && is_store_x` 要求两个信号属于**同一条动态指令**。五级 STORE 改到 MEM 时，把 `mem_start_x` 别名为 MEM 请求接受，却继续让 `is_store_x` 表示 EX 指令，会产生悄无声息的统计错误。CPU5 采用 `[新增] cpu5_d_req_fire`, `cpu5_d_owner_is_store`, `cpu5_bp_resolve_commit` 等明确阶段/年龄的观测信号；旧探针只有语义完全一致时才可保留同名。

## 2. 四组级间寄存器字段（必须有 `valid` 和年龄）

> 表中的 `_q` 是 CPU5 新字段名称；没有明列的组合译码可在本级计算，但跨级所需的异常、PC、预测、访存信息必须随指令保存，不能用实时 IF/ID 地址代替。

### 2.1 `IF/ID`：优先由原 `if_stage`+包装适配持有；ID 消费

| 字段 `[新增]` | 位宽 | 产生方 | 消费方 / 作用 |
|---|---:|---|---|
| `ifid_valid_q` | 1 | IF 请求/响应队列 | ID 允许译码/相关检查 |
| `ifid_pc_q` | 32 | IF 响应绑定的请求 PC | ID 分支目标、异常 PC |
| `ifid_instr_q` | 32 | I-Cache/ROM 响应 | decoder |
| `ifid_pred_next_pc_q` | 32 | IF 查询 BTB 的预测 | ID/EX 实际 next PC 对账 |
| `ifid_pred_taken_q`, `ifid_pred_hit_q` | 各 1 | IF 预测元信息 | 性能及训练 |
| `ifid_fetch_error_q` | 1 | IF 真实响应故障 | 提交时触发取指异常 |
| `ifid_fetch_tval_q` | 32 | IF 出错请求地址 | trap `mtval` / `imem_fault_pc` |
| `ifid_epoch_q` | 参数化小位宽 | IF 重定向代际 | stale 请求/响应失效 |
| `ifid_seq_q` | 仿真可选 | 接受动态指令时分配 | 唯一退休和年龄断言 |

消费规则：实际复用 `if_stage` 时，`ifid_valid/pc/instr/pred_*` 可以直接采用模块同步输出的别名/适配输出，**不允许把这些信号再无条件寄存一拍而不重算阶段时序**；但 `ifid_fetch_error_q/ifid_fetch_tval_q/epoch/seq` 未必有等价的原模块寄存输出，由适配器或 CPU5 自己补齐，尤其要处理原 `imem_fault` 的粘滞语义。ID 未 `ready` 不覆盖 `IF/ID`；I 端可以握手的响应必须入有效槽、回压或作为 stale 丢弃。绝不因为 ID 停顿而吞掉有效响应。已经 `req_valid && !req_ready` 的 I 请求保持地址/元信息；redirect 仅标 stale，不能违规撤销。I-Fetch fault 必须随对应 PC 排队，不能越过年长指令抢先 Trap。

### 2.2 `ID/EX`：由 ID 发射；EX 消费

| 字段 `[新增]` | 位宽 | 产生方 | 消费方 / 作用 |
|---|---:|---|---|
| `idex_valid_q`, `idex_pc_q`, `idex_instr_q` | 1/32/32 | ID | EX 执行及异常定位 |
| `idex_rs1_q`, `idex_rs2_q`, `idex_rd_q` | 各 5 | decoder | 前递/数据相关/写回 |
| `idex_uses_rs1_q`, `idex_uses_rs2_q`, `idex_writes_rd_q` | 各 1 | ID 译码 | 防止对 x0/未用操作数误判 |
| `idex_rs1_value_q`, `idex_rs2_value_q` | 各 32 | regfile + ID 前递 | EX 二次前递并执行 |
| `idex_imm_q`, `idex_imm_s_q`, `idex_imm_b_q`, `idex_imm_j_q` | 各 32 | decoder | ALU/Store/branch/jump |
| `idex_funct3_q` | 3 | decoder | LOAD 符号扩展/M 操作/CSR |
| `idex_alu_op_q` | 4 | decoder | ALU |
| `idex_is_load_q`, `idex_is_store_q`, `idex_is_branch_q`, `idex_is_jal_q`, `idex_is_jalr_q` | 各 1 | ID | EX 调度 |
| `idex_is_m_q`, `idex_is_csr_q`, `idex_is_mret_q`, `idex_is_fence_q` | 各 1 | ID | M/CSR/提交屏障 |
| `idex_csr_addr_q`, `idex_csr_write_intent_q` | 12/1 | ID | MEM 的 CSR 检查/更新 |
| `idex_pred_next_pc_q`, `idex_pred_taken_q`, `idex_pred_hit_q` | 32/1/1 | IF/ID | EX/MEM 实际对账 |
| `idex_exception_valid_q`, `idex_exception_cause_q`, `idex_exception_tval_q` | 1/32/32 | IF fault/ID 非法译码 | 随流水传递到 MEM |
| `idex_seq_q`, `idex_epoch_q` | 同 IF/ID | ID | age/stale 测试 |

`idex_imm_q` 可以按 ALU 类型多路选择，但为了减小 EX 组合链，建议 ID 提前形成原操作立即数；不允许在 ID/EX 和 EX/MEM 丢失立即数的语义。`CSR` 读写不能仅用 ID 早读旧 CSR 值作决定：通过 RAW stall 或 MEM 提交时重新读取、组合计算。

### 2.3 `EX/MEM`：由 EX 计算，MEM 独占提交

| 字段 `[新增]` | 位宽 | 产生方 | 消费方 / 作用 |
|---|---:|---|---|
| `exmem_valid_q`, `exmem_pc_q`, `exmem_instr_q`, `exmem_seq_q` | 1/32/32/可选 | EX | MEM 提交所有者 |
| `exmem_rd_q`, `exmem_writes_rd_q` | 5/1 | EX | MEM/WB / 旁路 |
| `exmem_alu_result_q`, `exmem_link_pc4_q` | 各 32 | EX | 写回、访存地址、PC+4 |
| `exmem_actual_next_pc_q`, `exmem_pred_next_pc_q` | 各 32 | EX/ID | 提交 `arch_next_pc` 与 BP 更新 |
| `exmem_branch_taken_q`, `exmem_branch_target_q`, `exmem_is_branch_q`, `exmem_is_jal_q`, `exmem_is_jalr_q` | 1/32/1/1/1 | EX/ID | 提交训练/重定向统计 |
| `exmem_is_load_q`, `exmem_is_store_q`, `exmem_mem_addr_q` | 1/1/32 | EX | MEM 请求、Trap `mtval` |
| `exmem_mem_size_q`, `exmem_mem_wstrb_q`, `exmem_mem_wdata_q` | 2/4/32 | EX 译码/前递 | 唯一不可变请求描述符 |
| `exmem_store_raw_q`, `exmem_mem_funct3_q` | 32/3 | EX | 完成后的 LOAD 扩展和 Store 诊断 |
| `exmem_mem_class_q` | 枚举 | EX 地址白名单 | `RAM_PURE_READ/RAM_STORE/MMIO/UNMAPPED` |
| `exmem_req_state_q` | 枚举 | 事务控制 | `NONE/PRESENTED/ACCEPTED/RSP_PENDING/COMPLETE` |
| `exmem_mem_order_barrier_q` | 1 | EX/地址分类 | 年长 STORE/MMIO/未知访问未完成时禁止年轻 EX LOAD `req_fire` |
| `exmem_commit_eligible_q` | 1 | MEM 仲裁 | 授权副作用请求；不直接等于退休完成 |
| `exmem_rsp_data_q`, `exmem_rsp_error_q` | 32/1 | D 端响应 | LOAD 写回/访存异常 |
| `exmem_result_ready_q` | 1 | EX/MEM | 前递资格，LOAD 未返回时为 0 |
| `exmem_exception_valid_q`, `exmem_exception_cause_q`, `exmem_exception_tval_q` | 1/32/32 | EX/IF 故障 | MEM Trap 仲裁 |
| `exmem_is_m_q`, `exmem_m_result_q`, `exmem_m_done_q` | 1/32/1 | M unit | 只有 **owner 匹配且未 killed** 的 M 完成才可提交 |
| `exmem_m_owner_seq_q`, `exmem_m_owner_killed_q` | seq/1 | M 控制 | 隔离失效 M；busy 完成后 drain/drop，不冒充新 M 结果 |
| `exmem_is_csr_q`, `exmem_is_mret_q`, `exmem_csr_addr_q`, `exmem_csr_write_intent_q`, `exmem_csr_operand_q` | 1/1/12/1/32 | EX/ID | MEM CSR 原子读-改-写 |
| `exmem_fence_q`, `exmem_epoch_q` | 1/小位宽 | EX | 总线 drain/冲刷 |

**所有者规定**：MEM 阶段持有该指令的提交资格。EX 发出的纯 RAM LOAD 在进入 EX/MEM 前将请求归属和 PC/seq 绑定到唯一 D 事务描述符；若本拍同时消费旧响应并接受新请求，旧响应属于**旧 MEM 指令**、新请求属于**新 EX 指令**，不得共用未区分的 `req_sent` 位。**MEM 中的年长未完成 STORE/外设请求优先级高于 EX 的年轻纯读**；默认只允许已完成的年长纯 RAM LOAD 与新纯 RAM LOAD 同拍交接，STORE→LOAD 同拍释放需额外证明写可见顺序。

### 2.4 `MEM/WB`：MEM 决定内容；WB 只负责 GPR

| 字段 `[新增]` | 位宽 | 产生方 | 消费方 / 作用 |
|---|---:|---|---|
| `memwb_valid_q`, `memwb_pc_q`, `memwb_instr_q`, `memwb_seq_q` | 1/32/32/可选 | MEM 成功退休 | WB 观察/对账 |
| `memwb_rd_q`, `memwb_writes_rd_q` | 5/1 | MEM | regfile 写端 |
| `memwb_result_q` | 32 | MEM 选择：ALU/LOAD/M/CSR read/PC+4 | WB/两级旁路 |
| `memwb_wb_kind_q` | 枚举 | MEM | 监视和统计 |
| `memwb_actual_next_pc_q` | 32 | MEM | debug / trace 对账 |

`[现有] wb_pc/wb_rd/wb_data/wb_we` 由 MEM/WB 映射；`[现有] retire_valid` 应由 MEM 退休事件在指定边沿寄存输出，并为 `instret_count` 提供同一观察窗口的明确定义（新旧允许固定对齐延迟不同，不能重复计数）。异常/被冲刷指令 `memwb_writes_rd_q=0`，不能写 GPR。

## 3. 相关检测、前递与插泡真值表

### 3.1 EX 级寄存器操作数选择（分别对 rs1/rs2）

设 `use_s` 表示本条确实使用源寄存器 s；每个生产者有 `valid`, `writes_rd`, `rd != 0`, `result_ready`。

| 优先级 | 命中条件 | EX 操作数 | 未就绪处理 |
|---:|---|---|---|
| 0 | `!use_s` | 不比较，不生成 stall | 无 |
| 1 | `s==x0` | `32'd0` | 无 |
| 2 | `exmem_valid && exmem_writes_rd && exmem_rd==s` | **只有** `exmem_result_ready` 才取 EX/MEM 结果 | 否则停顿，**不能回退用更老的 MEM/WB 同名寄存器** |
| 3 | `memwb_valid && memwb_writes_rd && memwb_rd==s` | `memwb_result_q` | 若需要保证同拍写回可见则 WB→ID/EX 旁路 |
| 4 | 无命中 | ID 保存的寄存器值，或新读的 regfile 值 | 无 |

生产者优先级为 EX/MEM 高于 MEM/WB；LOAD 结果未就绪、M 运算未完成、CSR 读值未就绪都禁止假前递。**不能用 `wb_we` 作为 MEM 退休事件的替代条件**。

### 3.2 ID 级分支比较/JALR 目标源寄存器

| 更老生产者所处级 | 指令结果 | ID 可以立即解析吗？ | 首版处理 |
|---|---|---|---|
| EX | ALU、PC+4、CSR/M、LOAD | 否（不引入 EX→ID 长组合前递） | ID 保持，EX 下拍插泡 |
| MEM | ALU/PC+4 且结果就绪 | 可以经 MEM→ID 前递 | ID 解析 |
| MEM | LOAD 未收到响应、M 未完成、CSR 未取得一致读值 | 不可以 | 等待结果可见；必要时再等一拍 |
| WB | 已有 GPR 写回数据 | 可以经 WB→ID 前递 | ID 解析 |
| 无 RAW | 本级 regfile 值 | 可以 | ID 解析 |

条件分支比较同时使用 rs1、rs2；JALR 使用 rs1；JAL 不依赖 GPR。预测错误事件必须随此指令经过年龄验证后再更新架构口径的 `bp_resolved_count` 等。ID 可提前驱动 IF redirect，但被年长异常覆盖时必须让其失效。

### 3.3 关键指令相邻情况（必须有测试）

| 相邻序列 | 相关源 | 期待动作 |
|---|---|---|
| `ADD x5,...; ADD x6,x5,...` | ALU→EX | EX/MEM→EX 前递，正常不插泡（无其他停顿时） |
| `LW x5,...; ADD x6,x5,...` | LOAD→EX | 命中数据就绪时可旁路；若不能及时在 EX 起始满足时序则**保守插 1 拍**，Miss 按响应长度等待 |
| `ADD x5,...; BEQ x5,...` | EX→ID | 默认 1 拍 ID 等待，不为零罚时引入 EX→ID 长路径 |
| `LW x5,...; BEQ x5,...` | LOAD→ID | 等待真实响应 + ID 旁路，**不保证仅 1 拍** |
| `LW x5,...; SW x5,...` | LOAD→store data | 要么在 EX 得到正确数据，要么在 MEM 提交前前递；禁止旧值进入 `wdata` |
| `ADD x5,...; CSRRS ... x5` | GPR→CSR | 保证 CSR 源操作数是最新值 |
| `CSRRW ...; CSRRS ...` | CSR→CSR | 按程序顺序提交/读到最新值，默认 CSR RAW 插泡 |
| `MUL x5,...; ADD x6,x5,...` | M→ALU | 在 M done 真正就绪后才放行 |
| `... x0 ...` | 常量寄存器 | 永远读 0，不产生伪相关和写回 |

**ID hazard 的真值准则**：如果更老的真实生产者命中而值尚不能使用，应停顿；不能因更老的 WB 同名值存在而绕过最新、但尚未就绪的生产者。分支解析级选择依据见 §8.5：不允许凭假设的 40% RAW 或统一一拍罚时直接锁定 ID/EX。Store 的地址 rs1 与数据 rs2 可以采用不同的使用时刻，但必须分别建 hazard/旁路规则。

## 4. D 总线授权、事务时序和提交安全

### 4.1 地址分类不是单纯 `!mmio_region_x`

`[现有] mmio_region_x = (mem_addr_x[31:16] == 16'h2000)` 只识别 CPU 内部本地 MMIO。**`0x30000000` 的 AXI CoreMark 统计设备不满足此判断，却有 START/STOP 快照读副作用。**

`[新增] cpu5_mem_class` 应先根据明确范围及操作类型分类：

| 类别 | 初版请求级 | 是否可在 EX 发起 | 依据 |
|---|---|---|---|
| `RAM_PURE_READ` | EX（经资格门控） | **允许** | 严格白名单：`[DMEM_BASE_ADDR, DMEM_BASE_ADDR+4*DMEM_WORDS)`，对齐、无外设读副作用 |
| `RAM_STORE` | MEM 独占提交 | **不允许** | BRAM 写在接受握手边沿永久发生；出错无法简单回滚 |
| `LOCAL_MMIO_READ/WRITE` | MEM 独占提交 | **不允许** | UART RX 弹 FIFO、GPIO、Timer、MSIP、UART 发送等 |
| `STATS_AXI_READ/WRITE` | MEM 独占提交 | **不允许** | `0x3000_0000` 的 START/STOP 读改变快照 |
| `OTHER_AXI/UNMAPPED` | MEM 独占提交 | **不允许** | 未知设备读也可能有副作用；由原从设备返回错误 |

采用 33/64 位拓展比较 `base+size`，防止地址相加溢出。RAM 范围还需确认具体 SoC 的地址镜像/别名；不能把“Cache 可以 bypass”当成“安全投机”。若前端支持任意外部内存映射，则缺少白名单时保守地全部走 MEM。

### 4.2 请求资格、年龄与副作用边界

**v0.3 D 端口仲裁硬规则（先检查年龄/顺序，再检查功能类别）**：

1. 一条动态指令首次呈现 D 请求必须取得唯一 `owner_seq`；每拍至多一个 `d_req_fire`。优先处理**年长 MEM 的已呈现/待发请求**，不能让年轻 EX 请求夺走端口。
2. 年长 MEM 有尚未完成的 STORE、MMIO、Stats 或未知 AXI 操作时，年轻 EX RAM LOAD **不得呈现也不得握手**。其请求排队在 EX，保持地址、`seq_id` 和所需 GPR 操作数。即使地址不同，首版也保守禁止越过；后续放宽必须有 RAW/WAW、设备排序和写可见性证明。
3. 若年长 D 请求 `valid && !ready`，请求描述符须稳定，后来的 EX 请求不得切换多路选择器覆盖它；该年长请求即使后来遭遇可延后的 IRQ，也必须按协议完成或有明确支持的取消流程。
4. **只对已成功完成且无异常的年长纯 RAM LOAD**，默认允许其响应与下一年轻纯 RAM LOAD 请求同拍交接。其他 `rsp_fire + req_fire` 组合首版保守停顿；若后续支持 STORE→LOAD 同拍交接，必须证明写在本拍对后续读可见。
5. 事务/提交顺序必须保证 `SW [A]; LW [A]` 读新值；同时验证 `SW [A]; LW [B]`、`LW [A]; LW [B]` 的无丢事务、无旧数据串扰；内存顺序判断不可仅比较地址是否相同。

`[新增] ex_ram_load_fire_allowed` 必须同时满足：

- `idex_valid_q && idex_is_load_q && class==RAM_PURE_READ`；地址正确对齐、无当前同步异常；
- 新 LOAD 未被年龄更老的 Trap/IRQ/MRET 冲刷；IF epoch 有效；
- 请求通路有所有者空位或可以与年长**已成功完成的纯 RAM LOAD** 同拍响应交接；
- `!older_mem_order_barrier`：不存在尚未完成的年长 STORE/MMIO/Stats/未知 AXI 及其未 drain 的请求；`older_mem_req_priority` 已得到满足；
- 若更老 MEM 是**非访存**或已经完成的纯 RAM LOAD，允许在不违反年龄/顺序门控时以非副作用投机读发起；该老指令随后 Trap 时，LOAD 的响应必须被丢弃，不能产生该 LOAD 的异常、寄存器写回或退休；**更老 STORE 或外设访问未完成时不允许例外**；
- `req_valid` 一旦呈现且 `req_ready=0`，描述符稳定；即使发生 redirect，也必须保持协议或通过设计允许的撤销接口（现有接口**不支持**任意撤销）。

`[新增] mem_side_effect_fire_allowed` 必须同时满足：

```text
exmem_valid_q
&& exmem_mem_class_q 是 STORE / MMIO / STATS / OTHER_AXI
&& exmem 在退休顺序上是最年长的未完成指令
&& !exmem_exception_valid_q
&& !mem_older_fault_pending
&& !mem_instruction_killed
&& !mem_req_already_accepted
&& !trap_take_older
```

这表示副作用操作首次对端口呈现有效请求时，就已具有提交资格。请求等待 `ready` 或响应时，IRQ 不得抢占它、导致重复执行；只允许它 drain 成功/失败后处理 IRQ。**同周期与年轻 EX LOAD 竞争 D 口时，MEM 副作用操作具有不可被旁路的优先权。**MEM 本身发生的总线错误在其响应返回时作为这条指令的异常处理。注意：错误的 STORE 若后端**已部分写入**，无法被 CPU 自动回滚；需保留旧总线故障的既有物理语义，不做不实的“事务原子回滚”承诺。

### 4.3 事务状态与所有权：不能简单复制三级 `req_sent`

- `[现有] mem_start_x`, `mem_active`, `req_sent`, `mem_req_fire`, `mem_rsp_fire`, `mem_rsp_success`, `mmio_endpoint_pending` 作为旧语义参考。
- `[新增] d_txn_valid_q`, `d_txn_owner_seq_q`, `d_txn_owner_pc_q`, `d_txn_epoch_q`, `d_txn_killed_q`, `d_txn_req_sent_q`, `d_txn_class_q`：指令-请求一对一绑定。`d_txn_epoch_q` **只用于追溯请求来自何时的 fetch**；不能用 `d_txn_epoch_q != fetch_epoch_current` 就直接判该 D 指令为 killed。
- `[新增] d_req_fire = dmem_req_valid && dmem_req_ready`；`[新增] d_rsp_fire = dmem_rsp_valid && dmem_rsp_ready`；两者可以同拍为 1，但必须分别关联旧响应 owner / 新请求 owner。
- 可采用**一个在途响应槽 + 一个新请求候选**的“同拍交接”实现：发生 `d_rsp_fire && d_req_fire` 时旧 owner 完成、新 owner 入槽，最后 `d_txn_valid_q=1`；若只有响应则清槽，只有请求则置槽。首版同拍交接**只开放年长成功的 RAM LOAD→年轻 RAM LOAD**；其余先以一个周期或实际 ready 为准，并保证老请求优先。
- `d_rsp_fire && d_txn_killed_q`：只 drain/drop，不生成 `retire_valid`、`wb_we`、`trap_valid`；请求错误也不作为路径内异常。
- 同一 owner 的 `d_req_fire` 计数最多一次。不能因 `rsp_ready=0` 重写 UART/GPIO/RAM。
- MMIO 仍保留 `[现有] mmio_endpoint_pending` 的寄存一拍描述符思路。`mmio_endpoint_fire` 是副作用真实发生边沿，不能从组合的 `valid_x` 直接推出外设 write enable。
- `[新增] d_req_select`：硬性优先 `held_request > oldest_commit_qualified_MEM > eligible_EX_RAM_LOAD`；若 MEM 属于尚未 drain 的 STORE/设备事务，直接对 EX LOAD 施加 backpressure。请求仲裁的选择只可在**空闲或上一次握手完成且协议允许换 owner**的边沿更新。

**吞吐声明的上限**：`data_cache.v:65` 证明其 RESPONSE 消费边沿有新的 `req_ready`；要验证 Core 实际 hit II=1，需要在 `cpu5_top` D 请求线上施测，不能只测 Cache 内部。Miss、写通、D0 router/BRAM 后端仍可能多拍，不能作为持续一拍接受所有请求的目标。

### 4.4 EX 发 LOAD / MEM 收响应的逐拍验收例

```text
C0: LOAD A 在 EX：地址/字节合法，发起 RAM 纯读；req_fire(A)=1
C1: LOAD A 在 MEM：rsp_valid(A)=1, rsp_ready=1；
    LOAD B 在 EX：如所有者支持同拍交接且也允许读，req_fire(B)=1
    => 对 A 执行 load_data 符号扩展并传 MEM/WB；绑定 B 为新 owner
C2: LOAD B 在 MEM：rsp_fire(B)=1；A 在 WB 写入 GPR
```

若请求迟迟不 `ready`、A 未命中或后端不能同拍交接，就依照反馈冻结上游，**不能为了保持 II=1 丢请求或覆盖响应数据**。对 LOAD-use，在未能提供准确可旁路结果前插泡。

**新增必须验收的对照序列**：`SW [A]; LW [A]`（LOAD 必须看到 STORE 新值），`SW [A]; LW [B]`（虽无地址别名也按首版顺序规则），`ECALL(MEM)+LW(EX)`（投机 LOAD 结果在老 Trap 后丢弃），`ECALL(MEM)+SW(EX)`（年轻 STORE 不得发请求），`RSP(LOAD A)+REQ(LOAD B)`（合法同拍交接）。所有序列同时测试 D Cache 命中、背压和错误响应。

## 5. Trap / CSR / IRQ / MRET / `arch_next_pc`

### 5.1 唯一 IRQ/退休边界（v0.3 冻结选择）

**本版本唯一选择：新出现的 IRQ 不与当前正常退休同拍接受；先完成本拍允许的退休，IRQ 在后续第一个安全边界阻止下一条尚未退休指令提交。若 IRQ 早已 armed，则它在当前安全边界优先于新一条普通退休。** 采用 `irq_arm_q`/待处理中断采样，`retire_fire` 与 `irq_take` **同拍互斥**；不采用“IRQ 与当前 MEM 指令同拍退休”的替代方案。MEM 内同步异常的优先权始终高于 IRQ。

- `[新增] mem_sync_fault`：最年长 MEM 候选在本周期已经确定的合法同步异常（含正确 owner 的 D fault），不含 killed/年轻响应。
- `[新增] retire_fire`：唯一正常完成的 MEM 指令，包含 GPR/STORE/CSR/MRET 等 **架构退休**；MRET 即便不写通用寄存器也需计入 `instret`。
- `[新增] irq_arm_q`：先前一个时钟边沿采样到、拟在**下一安全退休边界**评估的中断候选；状态必须在 `mstatus/mie/mip` 更新及同步后复核，不得直接锁死已失效的中断。
- `[新增] irq_safe_boundary`：没有已经呈现/接受而必须 drain 的年长 STORE/外设事务，没有在途年长 M/访存必须先完成的操作；IF/ID/EX 的可杀年轻指令不能构成阻塞条件，保证连续 ALU 流可以响应中断。
- `[新增] irq_take = irq_arm_q && irq_eligible_now && irq_safe_boundary && !mem_sync_fault`（并与本次 `retire_fire` 硬互斥）。`irq_eligible_now` 按**当前已提交 CSR**和同步 pending 判断；若此刻无效则撤销 arm，避免 CSR 关中断后错误进入。

**确定性选择表（一个边沿最多做一项架构动作）**：

| 同拍情况 | `retire_fire` | `irq_take` | `mepc` / 跟进 |
|---|---:|---:|---|
| MEM 最年长有同步异常 | 0 | 0（走 `sync_trap_take`） | `mepc=故障指令 PC`，Trap 抢占年轻 redirect |
| 年长不可撤销请求已呈现或等待响应 | 0，等完成 | 0，arm 保留或随 CSR 失效取消 | 不允许丢请求/重做侧效；事务完成后继续 |
| `irq_arm_q=1`，当前仍使能，且边界安全 | 0 | 1 | `mepc=arch_next_pc_q`，清空年轻指令，M 年轻 owner killed/drain |
| IRQ 本拍刚出现，但 arm 尚未置位；MEM 有正常完成指令 | 1 | 0 | 先提交此指令及 CSR，下一拍按**提交后的**使能条件判断 IRQ |
| CSR 指令写 `mstatus/mie` 完成 | 1 | 0（该拍若未预先 arm） | 用更新后的 CSR 资格在下一个边界检测 IRQ |
| MRET 正常完成 | 1 | 0（该拍若未预先 arm） | `arch_next_pc=mepc_target`，根据恢复后的 `mstatus` 在下一边界检测 IRQ |
| 连续 ALU 流，IRQ 已 arm 且使能 | 0 | 1 | 不可因为一直有可退休 ALU 就无限推迟 IRQ |
| 无异常、无可接受 IRQ，普通 MEM 指令完成 | 1 | 0 | 更新 `arch_next_pc`；年轻 ID redirect 仅在无更老冲突时生效 |

**取中断与前一条退休的关系**：若同一物理时钟沿已通过 `retire_fire` 提交指令，就**不能**在该沿再 `irq_take`；下一沿在本次更新后的 `arch_next_pc_q` 采样 `mepc`。已经获得可取消资格的年轻 EX 纯 RAM LOAD 需要 `killed+drain`；不可撤销 STORE/MMIO 已呈现或在途时必须先完成，不能在它中间转移。IRQ 若被重新允许则在其后最近的安全边界接受。

**事件覆盖范围**：复位最高；已确定的最年长同步异常；已 arm 的安全 IRQ；当前正常 MEM（含 MRET/CSR）退休；年轻 ID/EX 重定向。这里“先正常退休后 IRQ”是跨**相邻边沿**的规则，不是把 IRQ 永远排在每拍退休之后而造成饥饿。

旧三级的 `sync_trap_event`, `irq_event`, `mret_commit_x`, `normal_redirect_x`, `redirect_x`, `redirect_pc_x` 仅供对照。五级的年龄语义不能复用旧组合逻辑；需对 `CSR 写 MIE / MRET / ECALL / 连续 ALU / 在途 STORE / M 未完成` 分别出具波形与真值表。

### 5.2 CSR 语义

- 只支持现有地址：`mstatus(0x300)`, `misa(0x301)`, `mie(0x304)`, `mtvec(0x305)`, `mscratch(0x340)`, `mepc(0x341)`, `mcause(0x342)`, `mtval(0x343)`, `mip(0x344)`，及旧实现的只读零值 ID CSR。
- 与旧 RTL 一致：`misa` 由 `ENABLE_M` 决定，固定值 `0x40001100`（RV32IM）或 `0x40000100`（RV32I）；只写即忽略；`mie` 仅开放已启用 IRQ 源的位。
- `csr_write_intent_x` 规则保留：`CSRRW` 总有写意图，`CSRRS/CSRRC` 只有 `rs1/zimm!=0` 才写；`rd=x0` 抑制 GPR 写回。
- CSR read-modify-write 必须基于该指令在 MEM 轮到时的**最新 CSR 状态**。最简单的首版方法：CSR 指令进入相关窗口后暂停年轻依赖 CSR 读/MRET/Trap 控制，直至前条 CSR 提交；允许恢复后续优化。
- 同步 Trap 的 `mstatus`、`mepc`、`mcause`、`mtval` 更新只在胜出 Trap 的边沿发生；MRET 只能执行一次，按旧 RTL `MPIE/MIE/MPP` WARL 规则更新。
- IRQ 保持旧优先级 `MEIP > MSIP > MTIP`，异步外部中断经两级同步；源级电平不能因 CPU 清 Trap 而自行消除。

### 5.3 `arch_next_pc`、IRQ `mepc` 精确定义

`[现有] arch_next_pc` 是**最后一条已完成架构指令之后、下一条应该执行的 PC**，不能用投机 `[现有] pc_f`、IFID PC 或本拍尚未退休的 MEM PC 替代。五级唯一选择：

- 正常顺序退休：`arch_next_pc_next = commit_pc + 4`；成功跳转/分支退休：`arch_next_pc_next = actual_next_pc`；成功 MRET：`arch_next_pc_next = mepc_target`；同步 Trap/IRQ 进入后，按旧合同把后续执行指针改为 `mtvec`。
- **IRQ 与普通退休互斥，IRQ 边沿 `mepc = arch_next_pc_q`（上一次已退休之后的地址）**；该拍不会同时产生新的退休 PC。最年长未退休指令在被 IRQ 抢占时必须能够在 MRET 后重新执行，且此前没有产生副作用。
- 例如 `CSR 写 mstatus` 在 T0 退休并决定新的 MIE，T1 才评估允许中断及 `mepc`；`MRET` 在 T0 退休则 `arch_next_pc` 先变为旧 `mepc` 跳转目标，若恢复后使能中断，T1 取中断时 `mepc` 应是这个返回目标。
- 与旧三级的时序在不同拍数下比较时，以**架构事件和 PC 序列**对账，而不是要求 `irq_event` 在同一个 cycle 编号；不得把尚未定稿的“IRQ 抢当前 MEM 退休”描述继续作为并列方案。
- `imem_fault`、`imem_fault_pc` 来自与请求绑定的错误响应，不可用响应时的实时预测 PC。同步取指 fault 必须在年龄正确的故障指令成为最年长提交候选时取 Trap。

### 5.4 FENCE、取指错误、预测更新

- `FENCE` 依照现有保守顺序语义：仅当所有更老 D 事务已 drain、没有年轻错误路径副作用时退休。无 `FENCE.I` 扩展承诺。
- 分支在 ID 级可以先重定向，**但**老 MEM Trap/IRQ 优先，不能让 ID redirect 覆写已确定的 Trap `redirect_pc`。
- 预测器正常更新只在该控制指令架构允许退休或已证实可被正确解析的安全阶段进行；与老 Trap 同拍被冲刷的年轻分支不能训练。
- 对正在等待响应的旧 IF 请求沿用现有 `req_hold_q/fetch_pending_q/fetch_stale_q` 语义；可新建 FIFO/epoch 实现，但必须保证响应的 PC、错误和预测描述符归属不变。

### 5.5 Fetch epoch、流水年龄和 D owner 彼此独立

| 状态 | 判断对象 | 失效/存活规则 |
|---|---|---|
| `fetch_epoch_q` | IF 请求和 IF 响应是否属于被重定向前的前端路径 | `redirect` 使较旧请求响应标 stale；只用于 **IF 级请求/响应** |
| `ifid_seq_q/idex_seq_q/exmem_seq_q` | 同一条动态指令的**架构年龄** | 只按 `seq`、老年事件的冲刷年龄界限和 `killed` 判定 |
| `d_txn_owner_seq_q/d_txn_killed_q` | D 请求/响应属于哪条指令 | 只接受年龄正确且未 killed 的提交/异常；被 kill 的纯读 drain/drop |
| `m_owner_seq_q/m_owner_killed_q` | M 结果属于哪条指令 | 原 M 单元即使给出 `done`，若 owner killed，必须 drop 而不退休 |

**特别反例**：`LW A` 在 EX 已对 D 发出纯读，**更年轻**的 `BEQ` 在 ID 改写 fetch epoch。旧 fetch 请求须 stale，但 `LW A` 年龄比 `BEQ` 老，D owner **必须继续活着**，直到其正常退休或遭遇更老 Trap。禁止 `d_txn_killed = (owner_fetch_epoch != current_fetch_epoch)` 一类捷径。

增加测试 `older LOAD(EX) + younger ID branch redirect`、`older LOAD fault + younger redirect`、`older branch redirect + younger EX LOAD`（按确实存在的流水年龄组合）并核对 owner/epoch 追踪。年龄错误的响应不能误报 Trap，年龄正确的老 LOAD 错误不能被年轻分支掩盖。

## 6. Stall/flush 同拍仲裁与阶段写使能

**唯一事件顺序依照 §5.1**：复位 > 最年长 MEM 同步异常 > 已 arm 且边界安全的 IRQ > 本拍正常 MEM 退休（含 MRET、CSR）> 年轻分支 redirect。请求等待和 M 运算不是可以被高优先级事件“直接取消”的组合事件，而是 **决定安全边界与 drain/kill 的资源状态**。`irq_take && retire_fire` 在任何周期不得同时为 1。

| 同拍输入 | IF/ID | ID/EX | EX/MEM | MEM/WB | 必须保证 |
|---|---|---|---|---|---|
| `reset` | invalid | invalid | invalid | invalid | 请求协议状态清空；旧 RAM 写不回滚 |
| 老 MEM `trap_take` | flush/stale | flush | 故障指令消费，不退休 | 允许此前老 WB 正常写回 | 无年轻写请求/退休 |
| 安全 `irq_take` | flush/stale | flush | 根据采样边界持有或退休最老指令 | 老 WB 继续 | `mepc` 与边界一致 |
| `mret_take` | flush/stale | flush | MRET 已消费 | 旧 WB 正常写回 | 使用已提交 `mepc` |
| `mem_wait`（D 响应未就绪） | hold 或带弹性缓冲 | hold | hold | 若已有有效内容，允许独立 drain | 不重复请求、不覆盖旧结果 |
| `m_wait`（M 结果未就绪） | hold | hold EX 中 M 指令 | 年长 MEM 可先完成，之后 bubble | 继续 drain | **有活 owner 才能按 M 等待阻塞；已 killed 的 M 进入后台 drain，不能强迫 ISR 一直等待同一旧指令** |
| `id_hazard` | hold | 注 bubble（若 EX 可推进） | EX 正常向 MEM 推进 | WB 正常 | 不丢流水指令 |
| `id_redirect`（且无更老冲突） | 冲刷**更年轻 IF** 请求/槽 | 当前分支按 ID 解析策略推进 | **老于该分支的 EX/MEM 指令和 D owner 继续存活** | 正常推进 | fetch epoch 变化不能杀更老 LOAD |
| 正常流 | IF→ID | ID→EX | EX→MEM | MEM→WB | 每条有效指令只走一次 |

特别注意：**MEM 被阻塞时，WB 不能无限保持 `memwb_valid_q=1` 每拍重写/重复退休。** WB 可以每拍消费一次老内容并插泡；MEM 真正解除后再向 WB 送一个新有效项。`stall_x` 是三级的跨阶段总冻结名，五级应使用 `[新增] ifid_hold/idex_hold/exmem_hold/memwb_load/memwb_clear` 等明确控制。

### 6.1 M owner、冲刷与后台 drain 合同（v0.3 必须）

`rv32m_unit.v` 的 `start` 仅在 `IDLE` 被接受；启动后 MUL 走 `MUL_PRODUCT/MUL_RESULT`，DIV/REM 最多迭代 32 拍；**`done` 在完成后保持为 1 直到新 start/reset**。五级不能复用旧单槽 `m_active` 或将 `done` 直接当成“当前 EX M 结果”。

- `[新增] m_owner_valid_q, m_owner_seq_q, m_owner_pc_q, m_owner_killed_q, m_owner_op_q, m_start_accepted_q, m_result_consumed_q` 由 `cpu5_m_owner` 持有，绑定**实际被接受**的 start 边沿与动态指令。
- `m_start_allowed = M指令在EX有效 && !M单元占用 && 无待 drain 的旧 M owner && !被更老的已知 Trap/redirect 冲刷 && [如采用保守首版] 无更老未解决的异常风险`。不得每个 `m_wait` 拍重复 start。
- 年长 MEM LOAD/CSR 事后异常、IRQ 或年龄更老的控制重定向杀死该 M owner 时，置 `m_owner_killed_q=1`，其结果**仅后台排空，不进入 EX/MEM/retire/WB/CSR/BP**；允许流水转向 Trap，不能因为 `m_busy` 继续阻塞 Trap 提交。
- 已 killed 单元没有硬件 cancel：**在旧 M 真正 done 前不得接受新 M start**。旧 `done` 的持续高电平只完成一次 drain/drop；新 M 需新的 owner/start-generation 令牌，不能以旧 `done=1` 冒充新完成。新 start 后的 done 清零需要作为时序事实验证。
- 若首版选择禁止“老 LOAD 未决时启动年轻 DIV”，也必须实现 start gate、owner 标记及程序可继续运行的资源释放条件；此时 `old LOAD fault + young DIV` 的负测应验证 **未启动**。之后若解除该门控，必须改测 **正在 DIV + 老 LOAD fault + ISR MUL**，检查旧 DIV drain、新 MUL 等待资源后正确执行、无死锁和错误结果复用。
- **资源忙与流水年龄分离**：被冲刷的 M 可能仍 busy，这只能阻止下一条 M 的资源使用，不得使完全独立的 Trap 入口、CSR、普通 ALU 永久停顿。
- **M 快路径**：现有 DIV/REM 对除零、带符号 INT_MIN/-1 可在接受 `start` 的时钟边沿同步置 `done=1` 且 `busy=0`。owner 必须先于或同时于该边沿建立，不能因“没看到 busy”丢完成，也不能将旧 sticky `done` 解释为新结果。

### 6.2 额外同拍冲突定向测试

| 冲突 | 必须发生的行为 |
|---|---|
| MEM 老 STORE 待受理；EX 年轻纯 RAM LOAD | 老 STORE 获端口，年轻 LOAD 等待；同地址 LOAD 最终读到新值 |
| MEM 老 LOAD 返回 error；EX 年轻 DIV busy | 老 LOAD 触发 Trap；年轻 DIV killed 后后台 drain；ISR 新 MUL 不误用旧 done |
| EX 老纯 RAM LOAD 在途；ID 年轻分支 redirect | 只清年轻 fetch 请求；EX 的 LOAD owner 不可被 epoch 误杀 |
| 连续 ALU 退休与持续 IRQ | 在下一安全边界接受 IRQ；不得无限连续 `retire_fire` 让 IRQ 饥饿 |
| MRET 恢复 MIE 与 pending IRQ | MRET 先退休并更新 `arch_next_pc`；下一边界按恢复后的 MIE 取 IRQ |
| 已呈现 STORE 且 `ready=0`，IRQ 已 arm | STORE 的 req/addr/wdata 保持稳定并 drain；安全边界后才允许 IRQ |


## 7. 16 条必须实现的可执行不变量（A01–A12 保留，新增 A13–A16）

> 以下为**精确语义**，不是已经可以直接编译的 SVA；Codex 应把它们落实到具体寄存器名、采样边沿及 reset disable 条件，再做正反例自检。仿真辅助 `seq_id` 可在 `synthesis translate_off` 下存在。

| ID | 不变量 / 断言语义 | 负测应触发的错误 |
|---|---|---|
| **A01** | 所有级 `valid=0` 时不产生 `retire_valid`、GPR/CSR 写、外设写脉冲；bubble 是无副作用的 | 失效指令写回 |
| **A02** | 退休序号严格递增且每个 `seq_id` 只退休一次；`trap_take` 的故障指令不能 `retire` | 重复/乱序退休 |
| **A03** | 被老 Trap/IRQ/redirect 标 killed 的年轻指令永不 GPR 写回、STORE/MMIO side effect、CSR 提交、BP 架构训练 | 错误路径副作用 |
| **A04** | `wb_we -> wb_rd != 0`，`x0` 读值恒 0，`x0` 相关不插泡 | 写 x0/假 hazard |
| **A05** | 若 EX/MEM 和 MEM/WB 同时命中源寄存器，选较年轻 EX/MEM；若 EX/MEM 未 ready，则等待而非取老 MEM/WB 值 | 前递优先级错 |
| **A06** | `dmem_req_valid && !dmem_req_ready` 时地址/写标志/size/wdata/wstrb 在下一采样边沿保持稳定直到握手（reset 例外） | backpressure 修改请求 |
| **A07** | 每个 D owner `req_fire` 至多一次；每个 `rsp_fire` 必须能对应一个已接受且尚未完成的 owner；同拍交接归属正确 | 重发/无主响应 |
| **A08** | STORE/MMIO/STATS/OTHER_AXI `req_fire` 必须满足 oldest + commit-qualified；年轻或已 killed 的副作用请求不能被接受 | ECALL(MEM)+SW(EX) 故障注入 |
| **A09** | 一条 STORE 或 FIFO-pop 等外设副作用在合法接受时仅产生一次，`rsp_ready=0` 不能重放；请求失败/错误按既有接口处理 | 背压下重复写 |
| **A10** | 对已 killed 的纯 RAM LOAD，允许 drain 响应，但不退休、不写 GPR、不触发年轻异常；响应归属与 PC 固定 | 错误路径 LOAD error 泄漏 |
| **A11** | `trap_take` 在周期内胜过年轻 redirect/CSR commit/store；`trap_pc/cause/tval/mepc` 来自**正确年龄**的故障指令 | 老 LOAD 错误+年轻 JAL/CSR |
| **A12** | 退休边界的 `arch_next_pc` 与黄金退休轨迹一致；按照 §5.1，IRQ `mepc=arch_next_pc_q`，IRQ/正常退休**同拍互斥**；MRET 恢复 PC/状态正确 | 提前 IRQ、错 `mepc` 或同拍退休 |
| **A13** | 老 MEM 的 STORE/设备请求在未完成时，年轻 EX RAM LOAD 不能 `d_req_fire`；请求仲裁按年龄优先，`SW [A]; LW [A]` 必须读取更新后的值 | 年轻读越过年长写、读到旧值 |
| **A14** | 任一 M `done` 只有匹配、活着且未消费的 `m_owner_seq` 才能被使用；killed M 只 drain/drop，下一条 M 不可沿用旧 `done`；取消后程序仍有界推进 | 旧 DIV 冲刷后 ISR MUL 假完成/死锁 |
| **A15** | Fetch epoch 只控制 IF stale；D/M 指令 owner 仅按年龄与 kill 判断；年轻分支 redirect 不得杀更老 LOAD | 老 LOAD 被错误 epoch 冲刷或其 error 丢失 |
| **A16** | 按 §5.1 采样中断：`irq_take && retire_fire == 0`；若 IRQ 持续有效且安全边界持续可用，必须在有界周期内 `irq_take`，且 CSR/MRET 后的资格来自最新已提交状态 | 持续 ALU 导致 IRQ 饥饿、CSR/MRET 先后错 |

建议另外做一条非强制覆盖率检查：连续两条无关 RAM LOAD 命中时 `d_req_fire` 两个相邻时钟均成立，**只有在实验配置支持一拍吞吐且无其他阻塞时作为性能验收**；不要将它误写成全部配置永远成立的安全不变量。

## 8. 阶段 0.5：先核对计数与关键路径

### 8.1 A：原始六分类账本

本次上传工程的 performance 原始日志（总共 2,000 迭代）包含：

| 统计字段 | 窗口总数 | 每迭代约数 |
|---|---:|---:|
| `counter_cycles` | 847,759,143 | 423,880 |
| `counter_retired` | 579,416,342 | 289,708 |
| `cycle_work_other` | 635,792,342 | 317,896 |
| `cycle_ifetch_wait` | 19,964,531 | 9,982 |
| `cycle_data_read_wait` | 112,902,261 | 56,451 |
| `cycle_data_write_wait` | 56,669,428 | 28,335 |
| `cycle_local_mmio_wait` | 12 | 0.006 |
| `cycle_redirect_wait` | 22,430,569 | 11,215 |
| `bp_next_pc_mismatch` | 18,323,289 | 9,162 次事件（**非**等待拍数） |

**已确认**：六类之和等于 `counter_cycles`；`work_other - retired = 56,376,000`，除以 2,000 为 **28,188**，不能当成 ifetch 或纯 MUL 时间。以上每迭代四舍五入不能用于精确和式，验收必须用原始窗口整数。

### 8.2 A′：CPU5 十类互斥主周期（必须设计，先审计三级 M 分项）

原六类：`work_other / ifetch_wait / data_read_wait / data_write_wait / local_mmio_wait / redirect_wait`。CPU5 将 M 两类与 RAW 两类作为**四个新的一等主类别**，因此应为 **10 类**，而不是“六类+两类=八类”，或添加重复的 `muldiv_wait` 后再加 `mul_wait/div_wait` 导致双计。十类为：

| 主分类（互斥） | CPU5 精确定义的方向 |
|---|---|
| `cycle_local_mmio_wait` | 当前最年长阻塞 D 事务属于本地 MMIO，且阻止 MEM 进展 |
| `cycle_data_write_wait` | 当前阻塞 D 事务为非本地 STORE/写侧效 |
| `cycle_data_read_wait` | 当前阻塞 D 事务为非本地 LOAD/读侧效 |
| `cycle_mul_wait` | 多周期 M 指令正在实际阻塞 EX/MEM 进展且为 MUL 家族 |
| `cycle_div_wait` | 同上，且为 DIV/REM 家族；包含除零/溢出快路径按真实等待计数 |
| `cycle_load_use_wait` | 因在途 LOAD 结果未就绪，ID/EX 相关指令无法推进，并对本拍进展造成实际限制 |
| `cycle_id_hazard_wait` | 其他 ID RAW 依赖（尤其 EX→ID 分支/JALR），与 `load_use` 不重叠 |
| `cycle_redirect_wait` | 年龄有效的重定向实际造成可取用指令断档（不得以分支事件数替代等待周期） |
| `cycle_ifetch_wait` | **下游有容量和消费意愿且不受更老阻塞**，但前端不能供给有效下一条指令；包括 I 请求尚未被接受、响应未到、stale 排空等实际取指缺口，而非简单 `!valid_x`；`fetch_pending` 不是唯一判断条件 |
| `cycle_work_other` | 所有剩余已计数周期，包括正常流水并行、启动/排空、未细分控制开销 |

必须制定并在测试中固定**唯一优先级**：`local_mmio > data_write > data_read > mul > div > load_use > id_hazard > redirect > ifetch > other`。若多种原因同拍存在，以阻挡最年长有效进展的原因优先，再按表中的优先级消歧；每个统计周期恰好落入一个主类。此为**诊断归因策略**而非 ISA 事实：五级的退休与年轻级等待可以同时发生，一拍被归为某类不代表移除该瓶颈可净节省整整一拍。

**M 计数为必须**：三级阶段 0.5 就应使用测试平台观察 `[现有] m_start_x/m_complete_x/m_wait_x` 与 `instr_x[14:12]`，输出 `mul_start`, `mul_complete`, `div_start`, `div_complete`, `mul_wait`, `div_wait`；不仅要分 MUL/DIV/REM，还应记录启动至完成间隔、CPU 实际放行/退休延后。`MUL_PRODUCT/MUL_RESULT` 的单元 done 时刻不等于 CPU stall 周期。注意 `work_other-retired=56,376,000` 不能全部归因给单一 M 指令，测试须解释统计窗口的边界和完成拍。这里的 start/complete **事件数**可作为独立旁路计数，不能再次并入互斥总周期和式。

**地址/ABI 必须版本化**：保留旧 `axi_lite_coremark_stats.v` 的 schema 3、旧 CPU `[5:0]` 及旧三级固件/位流不变；CPU5 新统计设备使用新硬件 schema（建议 4）、新 `cycle_profile_schema`（建议 2）和 `[9:0]` 主事件接口，固件、读取器、检查器均须同步升级。为保留旧六类 START/STOP 寄存器位置与原 `0x200` 窗口，可以使用剩余空间布置**额外四类**：

| 额外类 | START（低/高 32 位） | STOP（低/高 32 位） |
|---|---|---|
| `mul_wait` | `0x180/0x184` | `0x1c0/0x1c4` |
| `div_wait` | `0x188/0x18c` | `0x1c8/0x1cc` |
| `load_use_wait` | `0x190/0x194` | `0x1d0/0x1d4` |
| `id_hazard_wait` | `0x198/0x19c` | `0x1d8/0x1dc` |

这四对是**规划地址、未经 RTL 验证**，必须与 SoC/AXI 地址窗口、固件访问保护、旧保留地址行为核对。在 START 区继续使用 `0x130/0x138/0x140...` 顺序追加第九类会与旧 STOP `0x140` 冲突。`0x30000000` 的统计窗口仍是具有副作用的设备访问区，START/STOP 冻结采样边界仍需对齐 `cycle_count`，不能只把高位 `perf_cycle_events` 接上就认为完成。

**测量口径分层**：十类主周期是互斥且 sum=`counter_cycles` 的诊断分区；另维护 `retire_valid`、M 启动/完成、RAW 发生次数、重定向次数、Cache 接受/响应等**非互斥事件计数**。两者不能相加；不能由某个等待桶等比例推算五级消除后所省的实际周期。五级不应再要求 `work_other==instret`。

### 8.3 B：访存请求接受间隔

- 在 Cache 独立单测、CPU→D-Cache 边界、D-Cache→D0 router 边界分别记录 `req_fire/rsp_fire`，分别测试 `LW-LW`、`LW-SW`、`SW-LW`，Hit/Miss/Backpressure、跨 line/way、非法地址。
- 每项记录**请求到响应延迟（latency）**和**相邻两笔请求接受的间隔（II）**，二者不可混淆。
- 对 CPU5 命中 LOAD 的目标是无相关情况下 II=1；不强迫 D0 后端 Miss/Write 也为 1。
- 同拍消费旧响应并接受新 LOAD，确保旧/新地址不同且数据不串、`req_sent`/owner 更新正确。

### 8.4 C：关键路径证据

- 从 RV32IM performance 最终路由 `.rtr` 导出 **Slow/Fast Top-3 Setup path**，包含起点、终点、logic/data path delay、cell/route 分布和 Clock info；另检查 Hold。
- 同时排查 `rv32m_unit` 的 `product_q` 乘法 APM/高半修正路径、`instr_x→decode→stall_x→IF`、D-Cache tag/rsp、BTB/ID branch 等候选。
- 旧 WNS `+2.447 ns` 对比新 `+1.269 ns` 是跨构建变化，**不能在未拿到 endpoint 前断言损失的 1.178 ns 就在乘法器**。上传 ZIP 的文档给出了摘要，未提供可直接复核的完整 `.rtr` Top-3 正文；此项当前状态为 **待导出**。

### 8.5 D：动态分支相邻 RAW 比例（不改可综合 RTL）

**目的**：决定 CPU5 的 `BRANCH_RESOLVE_IN_ID` 默认值。不可用假定的“40% 分支依赖”或静态相邻指令比例代替动态测量。

1. 使用现有短程 CoreMark/ROM 固件、独立观察 TB，在 `retire_valid` 对应边沿记录 `wb_pc`，再由**同版本程序 ROM/ELF 指令映像**以 PC 找到该退休指令的 32 位编码。旧 `cpu_top` 端口不提供退休指令编码；`instr_x` 不能在 `retire_valid` 采样沿冒充已退休指令。ROM 程序静态且不自修改才可直接按 PC 反查。
2. 按**动态退休顺序**而非 `branch_pc-4` 找前一条/前两条指令，译码其 `rd`、`writes_rd`、目标 `rd!=x0`、当前分支 `rs1/rs2` 与真实 `uses_rs*`。单独统计 `BEQ/BNE/BLT/BGE/BLTU/BGEU` 和 `JALR`；`JAL` 不使用 GPR 源寄存器，不应污染 RAW 分母。
3. **纯动态指令依赖距离**：按退休顺序与对应 ELF/ROM 编码统计 `B_dyn`（需读 GPR 的有效分支/JALR 条数）、`distance1_raw`（某源的最近有效写者恰为前一条动态退休指令）、`distance2_raw`（最近写者恰为前两条之一、且不是前一条；距离确为 2）、`distance3plus_raw`、按生产者 ALU/M/LOAD/CSR 分类的动态次数，以及 `R`（年龄有效的重定向事件）。`D2` **不得预先包含“数据尚未就绪”**；从静态映像和动态退休 PC 不能直接推断五级哪个周期 stall。对两源分支逐源识别最近写者并汇总每分支一次命中，避免双计；丢弃 `rd=x0`、无写意图或不使用该源的伪相关。这里 `Dload` 只表示生产者指令类别，**不**表示已经出现 LOAD-use 气泡。
4. **CPU5 独立测量实际数据就绪/停顿**：待五级 RTL 存在时，从 `valid/ready`, `id_hazard`, 前递选择、`d_rsp_fire`, `m_done`, `mem_wait`, `flush` 和 seq/PC 同步取数，分别给出 `hazard_observed_cycles`, `load_use_stall_cycles`, `id_branch_stall_cycles`, `unready_producer_cycles`, `stall_masked_by_older_event_cycles`。一条 RAW 可能被更老 Cache Miss 掩蔽，也可能被旁路解决：`distance2_raw` 只是 RAW 统计，不直接成为 CPI 损失。
5. 选择判据**不设固定 15%/30% 胜负线**。在“每次紧邻 RAW 导致 ID 额外插一拍、EX 比 ID 每次有效重定向额外一拍、没有其他重叠”的**仅作上限比较**模型下：`C_ID_EXTRA ≈ D1`，`C_EX_EXTRA ≈ R`，盈亏线 `D1/B_dyn ≈ R/B_dyn`。当前性能窗口的 `bp_resolved/2000≈57,271`（统计的是可预测 branch/JAL）和 `bp_next_pc_mismatch/2000≈9,162`，其比值约 `16.0%`，仅可作参照：二者计数集合不完全相同，且 EX 额外损失未必固定一拍。必须用同一运行窗口统计新的 `B_dyn/D1/R`，并在 CPU5 仿真与 STA 中 A/B 选择。
6. **双层验收、两张表而不是混合字段**：
   - **阶段 0.5（零综合 RTL）**：`branch_raw_trace.csv`：`seed,firmware_sha,branch_pc,opcode,branch_total,distance1_raw,distance2_raw,distance3plus_raw,raw_from_load,raw_from_m,redirect_events`；另给汇总，不写任何“数据未就绪”的推定值。
   - **CPU5 3A/4B（实测）**：`cpu5_hazard_cycles.csv`：`seed,firmware_sha,rtl_sha,seq_or_pc,source_reg,producer_seq,producer_age,producer_ready,forward_source,stall_reason,stall_cycles,masked_by_older_stall`，与总周期/退休观测对齐。没有探针就标 `NOT RUN`，不得用动态依赖条数冒充停顿周期。
   - A/B ID/EX 比较用同一固件、Cache/BTB 参数与 50 MHz 时钟，区分 `RAW 动态分布` 和 `真实气泡` 两组证据。可用单迭代 smoke/validation 先测，但不能伪称得到 2,000 次 performance 的精确分布。

### 8.6 E：观测设施迁移与清单闭合

- 已在本次上传 ZIP 中核实存在：`tb/coremark_d1_measure_tb.v`、`tools/analyze_d1_measure.py`、`tb/axi_write_profile_tb.v`、`docs/axi_write_profile.md`。`tb/coremark_d1_measure_tb.v` 用宏 `D1_CPU/D1_IF/D1_BP` 深度访问旧三级层次；其 M1 取 `mem_start_x && is_store_x`，M2 取 `bp_resolve_valid && bp_predictable_x`，**不能仅换层次前缀**而假设意义不变。
- 本次 ZIP **没有找到** `tb/coremark_axi_write_profile_tb.v`、`tools/analyze_coremark_axi_write_profile.py` 或 `docs/coremark_axi_write_profile.md`（部分 README 有残留引用）；若用户工作区另有较新文件，需先补齐来源与散列并重新清点。不能在当前交付物中声称这三份可直接复用。
- 新增 CPU5 观测接口合同：`cpu5_ifid_accept`, `cpu5_id_stall_reason`, `cpu5_ex_valid`, `cpu5_mem_commit_valid`, `cpu5_retire_seq`, `cpu5_d_req_fire`, `cpu5_d_rsp_fire`, `cpu5_d_owner_pc`, `cpu5_d_owner_is_store`, `cpu5_bp_resolve_commit`, `cpu5_bp_mispredict_commit`（命名可在首次 patch 锁定）。关键原则：**所有同拍组合的观测字段，必须绑定同一动态指令/owner**。
- M1/M2 和写通路 profiler 迁移采用单独 TB 适配层：先列出旧字段含义→新取数点→退休/握手边沿→计数窗口→CSV schema 对照，再改分析器。区分“源字段/名字保持兼容”和“物理事件语义已经改变”；若不等价，版本号必须升级，旧 CSV 数据不得混用。
- 新 CPU5 固件前置合约、`tools/regression_suites.json`、启动 STOP 快照、CSV 检查和 12 项断言一起纳入验收；没有相同版本的波形/CSV 时，只能标 `NOT RUN`。

## 9. 逐阶段实施与硬门

| 阶段 | 编码/验证顺序 | 不可跳过的门 |
|---|---|---|
| 0 | 从原 Git + release 冻结三级 RV32IM；**核对起点 `75c43a`、已验收源码 `347982c` 与板测证据 `ab8e3f6` 的不同角色** | Git 完整 SHA、对应源码/证据 manifest、双种子位流、UART、STA 均验证；ZIP 本身不能替代原 Git 历史 |
| 0.5 | **A** 原六类与 instret 复核；**A′** 强制拆 MUL/DIV、锁定 CPU5 十类 ABI；**B** 请求 II；**C** 路由 Top-3；**D** 动态分支 RAW（**不推导数据就绪**）；**E** profiler 清单与语义映射 | 原六类闭合、新十类设计与地址无冲突、M 分项计数可信、D/E 报告完整；CPU5 ready/stall 及新十类只能在 RTL 就绪后实测 |
| 1 | PLL 50 MHz 时钟链、`pll_locked` 同步释放、UART/mtime/约束和新独立 variant | 完整 50 MHz 回归；52/53 MHz 分档独立签核，不预设 54 MHz |
| 2 | ILA 一信号一次触发冒烟 | JTAG、实际采样可信；正式三组留后续 |
| **3A-1** | 新建 CPU5 IF/ID/EX/MEM/WB 有效位与整数 ALU、WB | `ADD/SUB/SHIFT/x0` 逐退休对账 |
| **3A-2** | 实现 EX/MEM→EX、MEM/WB→EX/ID 相关规则；据 D 结果选择或保留分支 ID/EX 参数 | 前递、load-use、branch-use、二级 RAW 与冲刷定向测试；原 `if_stage` 复用门通过 |
| **3A-3** | LOAD RAM EX 启动与 MEM 接收；STORE/MMIO 在 MEM 授权；**MEM 老请求优先，老 STORE 未完成时挡年轻 LOAD**；分支 ID 起步 | 真实 C 程序、`SW [A]; LW [A]` 与多笔握手正确；第一轮可只实现普通 RAM，不冒充全部 MMIO 支持 |
| **3B** | **实现最小同步异常/ECALL/Trap 入口**，故障注入、stale IF/D 响应、`ECALL+年轻 SW`、`older STORE + younger LW`、长背压、同拍握手；先固定 M owner/IRQ/epoch 设计合同 | **仅对已实现子集**执行 A01–A13、A15 的适用断言，A14（运行中 M）、A16（IRQ/MRET）及尚未实现的 CSR/MMIO 子项一律 `NOT IMPLEMENTED / NOT RUN`，不准全量 PASS |
| **4A** | RV32M、CSR RAW、完整 Trap/IRQ/MRET、M owner killed/drain、连续 ALU IRQ 边界 | 所有 A01–A16 在**已实现配置**下完成定向测试；M 中途被冲刷 + ISR MUL、CSR/MRET 同拍/后拍、IRQ 进度与 `mepc` 对账，未覆盖配置须标明 |
| **4B** | I/D Cache、D0、BTB、CPU5 十类计数器、M1/M2/写通路适配、MMIO 快照；补 CPU5 真实 ready/stall 报表 | 十类 one-hot/sum、schema4/2 同步、观察窗口对齐、跨配置 A01–A16 全量验收、现有全回归对应配置 + 双种子短程 CRC |
| 5 | **先 CPU5@50 MHz 与三级@50 MHz 用同编译器/固件和测量契约做架构/性能同频对照**；过门后 PLL 提频 80→90→100 MHz | 50 MHz 全回归、CPI/CoreMark-MHz/十类/资源同频 A/B；之后每档最终 STA + 上板 + 固件频率/哈希匹配，未通过不得以频率预测值报成绩 |
| 6 | 按 CPU5 十类归因、M 指标与 Top-3 path 选择 M 延迟、存储、I-Cache 或预测优化 | 每项 A/B 单因子对照；不能基于未证实的 2.1% 下结论 |
| 7 | 双种子正式成绩、三组 ILA、竞赛报告 | A01–A16 在正式变体的最终实现签核、双种子运行 ≥10 秒、CRC、`Correct operation validated`、现有工程约定的 `COREMARK RESULT: FORMAL PASS`；打印的 FORMAL PASS 不替代 RTL 形式化证明 |

### 9.1 三种互不替代的阶段验收状态

| 类型 | 何时判定 | 允许写 PASS 的证据 |
|---|---|---|
| **设计冻结**（SPEC FROZEN） | 3A RTL 开工前 | 端口/owner/副作用/IRQ 真值表和 A01–A16 **预期断言表**审查通过；并不意味着 RTL 已存在或断言已通过 |
| **阶段断言验收**（PARTIAL VERIFIED） | 3A、3B、4A 各阶段 | **已实现**功能的 testcase、assertion、目标参数组合有真实 transcript；未实现项逐条标 `NOT IMPLEMENTED`，未跑标 `NOT RUN` |
| **最终实现签核**（IMPLEMENTATION PASS） | 4B 全配置 + 5 同频 / 最终 7 | A01–A16 所有要求与相关配置完整通过，兼容 profiler、全回归、CPU5@50 MHz 同频、STA/双种子证据关联，不能用设计冻结或单个子集 PASS 代替 |

**特别纠正**：3B 不可能在 IRQ/MRET 尚未实现时宣布包含它们的 A12/A16 完整通过；3B 只能声明该阶段可达的断言子句 PASS。3B 首先实现最小同步 Trap 机制以支持 `ECALL + younger STORE` 故障注入，完整 CSR/MRET/IRQ 在 4A 开放。最终全配置的 A01–A16 验收在 4B/7 完成。设计合同不要求当前 ZIP 已有五级运行结果。

### 9.2 Codex 每个补丁的最小报告格式

每次独立 patch 必须提供：

```text
变更文件：...
保留三级代码/归档哈希：PASS / FAIL
编译 lint / ModelSim transcript：PASS / FAIL（命令、退出码）
本次新增定向 testcase：名称、期望、结果
退休 PC/instr/rd/value 对账：首个分歧及波形窗口（如有）
A01–A16 不变量：哪些已编码/哪些暂未编码（未实现/未运行分别标记，不准把 TODO 写成 PASS）
DDR/Cache/AXI req/rsp 和侧效计数：... 
性能证据：CPI / cycle 分类 / Fmax / 资源，仅写实测；未测标 TBD
```

新五级不应继续要求所有老 testbench 的固定拍数相同。必须提取其**指令及内存可观察行为**，使用新的五级 scoreboards；对于中断/外设时间相关场景，建立明确定义的采样边界与期望。

## 10. Codex 第一轮工作指令（不要直接完成整个五级）

0. **先完成 §8.5 D 与 §8.6 E（等效于 §10.0）**：不改可综合 RTL，测相邻动态分支 RAW（或标明尚未获得证据）、列出真实存在的 profiler 文件及其按指令年龄/握手边沿的字段语义。**D2 只计算动态 RAW 距离，不能声称是数据未就绪。**分支 ID/EX 解析级选择先保留参数，不做不可逆决定。同步执行 §0.1 的三类 Git 提交核查。
1. 只读审计上传工程中上述源文件与顶层变体，产出信号映射表；列出旧 testbench 依赖的具体层次名称，不允许修改旧实现。
2. 在新独立目录/文件内定义 `cpu5_top.v` 的**端口和四级间寄存器声明**、reset/valid 推进框架、候选 `if_stage.v` 复用适配接口以及最小的 `cpu5_hazard.v`；先写 §1.1 的七个 IF 复用门。声明 D 年龄仲裁、M owner/killed/drain、唯一 IRQ/retire 控制及 fetch epoch/owner 的不同用途；尚不连真实 Cache/CSR/MMIO。
3. 先写失败驱动的定向测试：`EX→ID branch RAW`、`MEM ECALL + EX younger STORE`、`older MEM STORE + younger EX LW same address`、`RSP(LOAD A)+REQ(LOAD B)` 同拍交接、`wrong-path RAM LOAD error`、`EX older LOAD + ID younger redirect`；同时补 `IF hold+redirect` 与 `sticky imem_fault` 的复用测试。提前编写但 **4A 才执行** `older LOAD fault + running DIV + handler MUL`、`continuous ALU IRQ`、`MRET then IRQ`，不得将尚未运行的测试写 PASS。
4. 然后逐增 ALU、简单 LOAD/STORE、**最小同步 Trap（3B）**、RV32M/完整 CSR/IRQ/MRET（4A）等；每个功能单独 commit 和回归，并更新 §9.1 的三类验收状态。
5. 未跑 ModelSim/STA/硬件时必须写 **NOT RUN**；尚未实现写 **NOT IMPLEMENTED**。最终完整五级后先 CPU5@50 MHz 同频回归/跑分，才允许开展 80/90/100 MHz 签核及正式 ILA。不得宣称 100 MHz、256 CoreMark 或 FORMAL PASS。

## 11. 进入 RTL 开发前的冻结判据

以下问题在本规格中**已有安全默认答案**，须在首个实现 patch 里显式参数化或注释确认；此处是 **设计冻结** 条件，而不是任何 RTL PASS：

1. ID/EX 分支解析通过 §8.5 的动态 RAW 与 A/B STA+IPC 决定；可先以 ID 保守插泡搭框架，但不可在没有证据时锁定 ID 为最终设计，更不可用“30%”作为无条件阈值。
2. RAM LOAD 的 EX 请求限定明确无副作用的地址范围，允许比 MEM 退休早一拍且可能被冲刷；被冲刷则 drain/drop，不能产生 Trap 或 WB；**更老 MEM STORE/设备事务未完成时不得越过**。
3. STORE/全部 MMIO/Stats/未知 AXI 必须等 MEM 成为最年长可提交候选，端口请求接受边沿有副作用，所以**不可依赖单笔在途来补救年龄错误**。
4. D 请求完成与下一请求同拍交接要独立 owner；**端口优先给年长 MEM，默认只放行纯 RAM LOAD→LOAD 同拍交接**；背压/路由不支持则正确停顿，不能强推 II=1。
5. 多周期 M 运算必须持有 `owner_seq/killed/drain`，区分快路径、新 start、旧 sticky done；CSR 提交只一次。**IRQ 按 §5.1 在下一安全边界抢占下一条未退休指令**，不能打断年长不可撤销事务。
6. `retire_fire` 与 `irq_take` 必须互斥，`mepc=arch_next_pc_q`，CSR/MRET 后新 MIE 的生效边界唯一；持续 ALU 期间 IRQ 有界进入。精确退休、异常和 `arch_next_pc` 优先于所有 CPI/Fmax 目标。
7. 原 `if_stage.v` 优先复用，但必须通过 §1.1 所列的七项功能门；sticky `imem_fault` 与停顿/redirect 并发必须在 CPU5 适配层保持正确；失败时允许新建 `if_stage5.v`，旧文件不可覆盖。
8. 同名 profiler 信号不得跨级改义。先按 §8.6 完成 D1/M1/M2 的字段同源/同年龄审计，CPU5 统计采用独立十类 schema，所有新增窗口地址不得和旧 STOP 银行重叠。
9. Fetch epoch 只用于 IF 请求 stale，流水指令与 D/M owner 必须基于年龄及 killed 标志；年轻 ID redirect 不杀更老 EX LOAD。
10. §8.5 的动态 D1/D2 RAW **只证明依赖距离**；五级实际数据就绪、旁路以及 stall 必须从 CPU5 波形/探针单独证明。
11. 0 阶段的 Git tag 必须以验真的已验收 RV32IM 源码 SHA（审查候选 `347982c`）为准，并链接板测证据 SHA（审查候选 `ab8e3f6`）；起点 `75c43a` 不得误用。
12. 3B 未实现 IRQ/MRET 前只能报阶段适用断言；4A 全功能、4B 全配置通过后才能申请最终 PASS。CPU5@50 MHz 同频验收必须先于任何正式提频成绩。

**本文件为设计与验收合同，非性能签核或综合报告。** **设计冻结前**必须具备阶段 0.5 的实测报告或准确标记其缺口、Git 提交核对、接口/owner/年龄/IRQ 真值表签署；**实现阶段**再追加 CPU5 十类快照、CPU5 ready/stall、A01–A16 定向断言；**最终实现签核**需独立 50 MHz 同频 A/B、全回归、STA/位流与双种子板测证据。不得在五级 RTL 尚不存在时要求它的测试 PASS，也不得凭估计改写已验收的三级成绩。
