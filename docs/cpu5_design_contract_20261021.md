# CPU5 设计合同与预期断言表

日期：2026-10-21。依据 `cpu5_arch_spec_v0_3.md` §§1–7、9–11，以及阶段 0 / 0.5 的实测证据。本文是实现前合同；**设计冻结不等于 RTL 已实现、断言已通过或性能签核**。本轮独立骨架、IF 适配和 hazard 单元的局部结果由阶段报告另列，不能覆盖下表的完整 CPU5 状态。

## 1. 范围、版本和唯一选择

- 原 `cpu_top.v`、`if_stage.v`、`rv32m_unit.v`、三级 SoC/Stats/位流保持原样；CPU5 独立文件，不接正式板顶。此次为 **scaffold / 规格 §10.1–2**，不是 §9 阶段1的PLL工作。PLL、ILA、ALU 执行、LOAD/STORE、Trap、CSR、IRQ、M 和十类 Stats 的实现不属于本轮骨架交付。
- 单发射、顺序执行、顺序退休；MEM 唯一决定架构退休，WB 仅执行已获准的 GPR 写回。无 ROB、无非阻塞多 LOAD、无 STORE 缓冲。
- 完整 CPU5 的基准配置保持 50 MHz。无本轮 CPU5 STA、资源、CoreMark 或最高频率结论；三级最终 Setup `+1.269 ns` 不能换算成 CPU5 成绩。
- `BRANCH_RESOLVE_IN_ID` 保留 A/B 参数；当前 smoke 的 D1/B=42.56% / 42.98%，同集合 R/B=15.35% / 15.24%，支持继续评估 EX，**不锁定最终解析级**。RAW 条数不能冒充 CPU5 实际 stall。
- CPU5 采用独立 schema4 / cycle_profile_schema2 / 十位事件，详细地址和计数边沿沿用 `cpu5_cycle_profile_contract.json`。旧 schema3/profile1 六位模块不变。

## 2. 采样边沿与接口合同

`E` 表示 `posedge clk`；组合 valid/ready、owner、动作许可均在 E 的 pre-NBA 值判定，寄存器在 E 后更新。下文“同拍”只指同一个 E。reset 为异步低有效；reset 释放应由未来 SoC 的同步复位链完成。验证器须区分 pre-edge 动作与 post-NBA 寄存观测。

| 接口 / 事件 | E 的含义 | 持有及后续规则 |
|---|---|---|
| `imem_req_valid && imem_req_ready` | 接受一笔取指请求，绑定 PC 和预测描述符 | 已呈现而未 ready 的请求不能撤销或改地址；redirect 标 stale 后仍完成协议 |
| `imem_rsp_valid && imem_rsp_ready` | 响应属于已接受的旧 IF 请求 | 正确路径响应形成一个 IF/ID 包；stale 响应只 drain；error 必须和请求 PC 绑定 |
| `cpu5_ifid_accept` | 新动态包首次进入 IF/ID 槽 | 只分配一次 seq；held 包不重新分配；取指 fault 也是有年龄的包 |
| `ifid_valid && id_ready` | IF/ID 包被 ID/EX 接受 | 未接受保持整包；`redirect` 只能按冲刷源年龄决定是否消费/丢弃 |
| `pc_x/instr_x/valid_x` | CPU5 当前 EX 的同一动态指令 | 原 `u_if_stage.pc_x/instr_x/valid_x` 实际是候选 IF/ID，不能与 CPU5 EX 伪绑 |
| `cpu5_d_req_fire` | D 请求在 E 被端口接受，绑定新 owner | 每 owner 至多一次；这不是旧三级 `mem_start_x` |
| `cpu5_d_rsp_fire` | D 响应在 E 被消费，属于 E 前保存的旧 owner | 与新请求同拍时必须先引用旧 owner，随后更新为新 owner |
| `cpu5_m_start_fire` | 原 M 单元在 IDLE 接受 start | 同时保存 owner/op/PC/seq/start-generation；busy=0 不等于无快路径结果 |
| `cpu5_mem_commit_valid` / `retire_fire` | MEM 本边沿批准正常架构退休 | 同步 fault 和 IRQ take 当拍均为 0；STORE/CSR/MRET 也可退休，不等于 GPR write |
| `retire_valid` | E 后寄存显示 E 的 `retire_fire` | 配套 `retire_pc/instr/seq` 同边沿捕获；不可用实时 EX 指令拼接 |
| `wb_pc/rd/data/we` | MEM/WB 的已退休指令写 GPR | GPR 写端在消费该 MEM/WB 包的唯一边沿生效；rd=0 强制不写；老 WB 可与年轻 Trap 并行 |
| `instret_count` | E 直接按 E 的 `retire_fire` 加一 | 不再追加延迟的 `retire_valid`；外部 pre-edge 读看到 E 前值，snapshot 必须同口径测试 |
| `trap_valid/pc/cause/tval` | E 后显示 E 胜出的 Trap 描述符 | cause/PC/owner 同源；粘滞 IF fault 不能越过老指令直接触发 |
| `cpu5_bp_resolve_commit` | 本边沿控制指令获准架构解析/退休 | seq/PC/预测/实际 next-PC 同源；错误路径不训练，一条指令一次 |

完整实现时 `cycle_count` 的使能和十类注册事件必须满足已有机器 ABI 的 snapshot-next 对齐合同。此项尚未实现；不能把上述边沿约定称为 Stats 验收通过。旧三级 `retire_valid` 相对完成边沿延迟一拍、instret 再消费它的事实已在测量中独立对齐，CPU5 不依赖旧内部延迟获得伪兼容。

四组级间包包含规格 §2 的全部必要字段；跨级必须保存 PC/instr/seq、真实 uses/writes、预测、异常、访存、CSR/M 信息。首轮未执行骨架可只推进 valid/metadata，所有 `retire_valid/wb_we/trap_valid/d_req_valid/m_start/CSR write/BP train` 均保持 0；骨架推进不能算 ISA 退休。

## 3. 64 位年龄和 Fetch epoch

- `seq_id` 固定 64 位无符号（本轮 `SEQ_BITS=64`），reset 后从 0 分配。新 IF/ID 包只分配一次，同一包 stall/转级/drain 不改变 seq；分配号允许因 killed 包产生退休间隙。Fetch epoch 本轮 `EPOCH_BITS=8`，不得因此缩窄 owner 年龄。
- 本版不支持 seq 回卷。年龄函数 `older(a,b) := unsigned64(a) < unsigned64(b)`；不得截成 32 位或用 signed32 差值。到达分配上限时停止接受、仿真报错，必须经 reset 才重用序号。正常板测不存在耗尽风险，但验证不能让溢出静默改变年龄。
- 对源 seq=`s` 的一般年轻冲刷，`killed(x) := x.valid && older(s,x.seq)`；源自身是否消费由事件定义：同步 Trap 消费故障源且不退休；正常分支源保留；IRQ kill 所有尚未退休的可取消指令。已退休 MEM/WB 从不被年轻事件取消。
- `fetch_epoch` 仅表示 IF 请求路径代际。redirect 会使旧 IF 在途/held 响应 stale；现有单在途实现的 sticky stale 判据优先于 epoch 相等，不能只靠小位宽相等在多次 redirect 后“复活”旧请求。
- IF/ID 接纳后，流水 live 判据由 seq 与 killed 控制。D/M owner 可保存 fetch epoch 追溯，但**绝不用 `owner_epoch != current_fetch_epoch` 杀 D/M**。
- 反例必须保留：更老 EX LOAD 已发请求，更年轻 ID branch redirect 改 epoch，LOAD owner 继续活着；若它返回 error，应在正确 MEM 年龄取 Trap，年轻 branch 不能遮蔽错误。

## 4. D 事务、请求授权与副作用

### 4.1 地址与权限

使用拓展 33/64 位无溢出范围比较，核对白名单 `[DMEM_BASE_ADDR, DMEM_BASE_ADDR + 4*DMEM_WORDS)`、访问宽度、对齐及末字节。只有该范围的普通 RAM LOAD 可在 EX 纯读投机。RAM STORE、全部本地 MMIO、`0x30000000` Stats START/STOP 读写、其他/未知 AXI 均在最年长 MEM 获得提交资格后呈现请求。未知读视为可能有副作用，不能以 `!local_mmio` 推断安全。

副作用许可在**首次呈现 valid 前**成立，不能等 req_fire 后再发现年轻。资格包括 live、oldest、无同步 fault、无更老冲刷、未接受过。STORE 等待 ready 时不得被 IRQ 打断或撤销。总线 error 保持既有物理语义；若设备已部分写入，不承诺 CPU 自动回滚。

### 4.2 唯一描述符和状态

独立 D 描述符至少包含 `valid,owner_seq,owner_pc,owner_instr,class,is_write,addr,size,wdata,wstrb,load_funct3,fetch_epoch(trace-only),killed,req_sent,rsp_data,rsp_error`。状态为 `NONE → PRESENTED → ACCEPTED/RSP_PENDING → COMPLETE`；已呈现未 ready 仍占描述符，不能被年轻请求覆盖。数据/控制字段在 valid&&!ready 期间稳定，kill 只改变可变的内部 killed 标记，不改变端口请求。

请求选择唯一优先级：`held_request > oldest commit-qualified MEM request > eligible EX RAM LOAD`。老 MEM 未完成 STORE/MMIO/Stats/unknown AXI 时，年轻 EX LOAD 不得呈现/握手，地址是否不同都不例外。老 MEM 同步异常当拍不允许年轻 EX 新请求；先前已呈现的可取消纯读按原协议完成并置 killed。

首版只开放**成功、未 killed 的老纯 RAM LOAD 响应 + 年轻纯 RAM LOAD 请求**同拍交接；STORE→LOAD、MMIO→LOAD、error→新请求、killed-drain→新请求均至少插一个边沿。端点不 ready 就停顿，不强迫 D0 miss/write II=1。

| `old_rsp_fire` | `new_req_fire` | E 的消费 | E 后 owner |
|---:|---:|---|---|
| 0 | 0 | 无 | 保持 |
| 0 | 1 | 绑定新描述符，必须无旧未完成 owner | 新 owner valid |
| 1 | 0 | 只消费旧 owner | 清空 |
| 1 | 1 | 先消费旧 owner A，再绑定新 owner B；只准上述 LOAD→LOAD | B valid，不能被清空优先级覆盖 |

`rsp_fire && old_owner.killed` 只 drop，不产生 retire/GPR/Trap/CSR/BP。每 owner 请求恰好至多一次、响应恰好一次。MMIO 的真实 `endpoint_fire` 与描述符同源，UART pop / write-enable 不可从 EX 组合 valid 推断。回压不能重放副作用。

必要顺序 oracle：`SW[A];LW[A]` 读新值；`SW[A];LW[B]` 也保守顺序；`ECALL(MEM)+SW(EX)` 年轻 STORE 零请求；`ECALL(MEM)+LW(EX)` 已发纯读 killed+drain；`RSP(A)+REQ(B)` 使用不同地址、不同返回数据校验旧/新 owner。测量只证明 Cache 入口 hit II=1、旧 CPU 全链最短 II=2；CPU5 II=1 仍是未来性能门。

## 5. M owner、sticky done 和 drain

不修改原 `rv32m_unit`。M 包装保存 `owner_valid,owner_seq,owner_pc,owner_op,owner_killed,start_generation,result_generation,result_consumed,drain`。start 只在资源无 owner、旧 drain 完成、EX M live、无更老确定冲刷时发一次。首个接入版本采用**保守门**：老 MEM 有未解决异常风险/访存时不启动年轻 M；该门不代替 owner/killed 实现。

- 正常 MUL 的 unit post-edge done=+2、普通 DIV/REM=+32；旧 CPU complete/retire 延后是旧实现事实，CPU5 必须重新测，不假定保持旧拍数。
- DIV/REM 除零和有符号 INT_MIN/-1 在接受 start 的同一 E 后置 `done=1,busy=0`。start-generation 同边沿建立；本次新结果最早在 E+1 的 pre-edge 消费，不能在 E 把旧 sticky done 当新结果，也不能要求先看 busy=1。
- 旧 `done` 高电平只能完成同 generation 一次。新 start 边沿禁止 result_consume；下个边沿只认新 generation 的结果。正常操作 start 后 done 清零；快路径不需要出现可观测的低电平，代际令牌是必要条件。
- 被更老 Trap/IRQ/redirect kill 后保持 owner、标 killed，busy 继续运行；done 后仅 drain/drop 一次并释放。旧结果不可进入 EX/MEM、退休、GPR、CSR 或 BP。
- killed M 的资源 busy 只阻塞新的 M；Trap 入口、CSR、ALU 仍可推进。ISR MUL 等资源释放后发新 start，不得复用旧 done。若先采用保守 start gate，`older LOAD fault+young DIV` 的首版负测期望为**DIV 未启动**；将来开放重叠必须改为“运行中 DIV 被 kill+ISR MUL”实测。

## 6. IRQ/退休唯一真值表

唯一架构动作顺序：`reset > oldest MEM sync fault > armed+eligible+safe IRQ > normal MEM retire (含CSR/MRET) > younger branch redirect`。irq_take 和 retire_fire 绝对互斥。旧 WB 可以在此边沿写入已退休结果，不属于新退休。

`irq_arm_q` 是此前边沿形成的待复核候选，不能把当时 MIE 锁死为以后资格。每个 E 使用**E 前已提交的** `mstatus/mie/mip` 重新计算 `irq_eligible_now`，采用 MEIP>MSIP>MTIP。唯一更新算法：先用旧 arm 和 E 前已提交状态决定本 E 是否 take；若本 E 正常退休，计算该退休后的 CSR 状态，再令 `arm_next = pending_sync && eligible(post_commit_CSR)`；没有正常退休则以当前 CSR 计算；Trap/IRQ 进入后的 MIE=0 因而清 arm。这里 post_commit_CSR 仅用于生成下一候选，绝不让尚未退休的 CSR 影响本 E 的 IRQ 仲裁。源消失/禁用则撤销；外部 IRQ 经两级同步。

因此 T0 CSR 开启 MIE 或 MRET 恢复 MIE 时，即便 T0 的旧 MIE=0，也能在该退休边沿生成 arm_next，T1 按新的已提交状态 take；不会因“旧状态不使能先清 arm”多等到 T2。若 T0 已 armed+eligible+safe，IRQ 先于未退休 CSR-disable，不能用该未提交写值屏蔽 IRQ。这是设计参考算法，IRQ RTL 本轮尚未实现。

`irq_safe_boundary` 不以年轻 IF/ID/EX 非空为阻塞；不存在已呈现/接受的不可撤销 D 请求、需先完成的年长 D/M owner。可取消年轻纯读/M 被 kill 后 drain，不能作为无限延迟 Trap 入口的理由。普通 ALU 流安全且 pending 持续时，从首次被同步采样的 E 到 E+1 必须 take；有协议 drain 的情况没有固定拍数上限，解除阻塞后的第一个安全边沿必须 take。

| E 前状态 / 事件 | `sync_trap_take` | `retire_fire` | `irq_take` | E 后动作 |
|---|---:|---:|---:|---|
| 最年长 MEM 同步 fault（含正确 owner error） | 1 | 0 | 0 | mepc=fault PC；更新 cause/tval；kill年轻；arch_next_pc=mtvec |
| 不可撤销请求已呈现/在途，尚未完成 | 0 | 0 | 0 | 描述符稳定并继续 drain；arm采样/复核 |
| 上述请求本 E 成功完成且可正常退休 | 0 | 1 | 0 | 退休此 owner；下一安全边沿再 IRQ；若 error 则转第一行 |
| arm=1、eligible=1、safe=1 | 0 | 0 | 1 | mepc=E前arch_next_pc；kill所有未退休可取消指令；arch_next_pc=mtvec |
| arm=1但本 E 已提交状态使资格无效 | 0 | 允许正常完成 | 0 | 撤销无效arm；不锁住CSR旧资格 |
| pending本 E首次采样、arm=0、普通MEM完成 | 0 | 1 | 0 | 本条退休；记录pending候选供下一E复核 |
| CSR在T0写MIE/mie，T0未预先armed安全IRQ | 0 | 1 | 0 | T0提交CSR和arch_next_pc；T1用新CSR复核pending |
| MRET在T0完成，T0未预先armed安全IRQ | 0 | 1 | 0 | T0先更新MIE/PC为返回目标；T1可IRQ，mepc=该目标 |
| 连续ALU、arm已有效且safe | 0 | 0 | 1 | 阻止当前未退休ALU；不能每拍退休导致IRQ饥饿 |
| 无fault/可接受IRQ且MEM正常完成 | 0 | 1 | 0 | 顺序+4、branch实际nextPC或MRET目标更新arch_next_pc |

若已经 armed 且当前提交状态使能，IRQ 在安全边沿优先于即将执行的 CSR-disable/MRET；未退休指令不能预先改变 CSR 阻止 IRQ。T0 CSR-disable 成功退休只可能发生在 T0 IRQ 不可接受时；T1 使用已关闭 MIE，不能取已失效 IRQ。

IRQ 不与本 E 正常退休合并：`mepc=arch_next_pc_q`，不是 IF PC、实时 EX PC、未退休 MEM PC 或本 E speculative target。IRQ 抢占的 MEM 指令不退休并需可重新执行；不可撤销请求完成前先不取 IRQ。同步 Trap/MRET 更新 WARL 状态一次。CSR RMW 在 MEM 读取最新提交值，CSR RAW 默认串行；FENCE 等所有老 D drain 后才退休。

## 7. 规格歧义的安全解释

1. §4.2 的“IF epoch有效”按 §§0.2/5.5 解释为“指令已通过年龄/killed live 检查”，**不做 owner_epoch=current_fetch_epoch 的额外门**。
2. §6 IRQ 表“持有或退休最老指令”不得覆盖 §5 的唯一真值：irq_take 当拍 retire_fire=0，未退休 MEM 可取消包被 kill；不可撤销 owner 先完成/退休，下一安全边沿才 take。
3. §5 等待不可撤销请求行的 retire=0 仅指未完成；成功响应边沿允许该 owner 完成并退休，否则永远无法腾出安全边界。
4. old held 请求即使遇到 kill 也不撤销 valid。只有先前合法呈现的纯读可能在 kill 后握手，随后 drain；新的错误路径请求禁止首次呈现。
5. 骨架 `flush_cut_seq` 表示**第一条被 kill 的序号**，不是事件源本身：正常 branch 使用 source+1，同步 Trap 使用 fault source，IRQ 使用首条未退休序号。上游 IF/ID 必须在同一 flush 协议清掉被 kill 的包；仅拉低 ready 不等于消费它。EX/MEM 明确携带预测 taken/hit，不能从 next-PC 猜回方向元信息。
6. seq 的全 1 值保留为耗尽停机标记。适配器达到它时屏蔽 IF/ID valid，保留协议状态并报仿真 fatal；这不是正常继续执行/退休策略，必须 reset 恢复，不承诺停机状态完成最后一个包。

## 8. A01–A16 预期断言与阶段门

以下均为**完整 CPU5 功能断言**。本轮统一实现状态 `NOT IMPLEMENTED`、运行状态 `NOT RUN`。阶段报告可以单列 IF/hazard/valid metadata 的已跑局部测试，但不可把局部合同测试写为完整 Axx PASS。每个断言在 rst_n=0 禁用；E 前采动作、E 后验证寄存描述符，next-cycle 稳定性在下一 E 比较。

| ID | 预期可执行检查 | 首次适用 / 完整门 | 计划正例与故障注入 | 当前状态 |
|---|---|---|---|---|
| A01 | 无有效owner/级包不产生退休、GPR/CSR/外设写；bubble零侧效 | 3A-1；CSR/MMIO到4A/4B补齐 | T01 reset/bubble；注入invalid写使能须失败 | NOT IMPLEMENTED / NOT RUN |
| A02 | 退休seq严格递增且唯一；故障源不退休 | 3A-1正常；3B异常；4B全配置 | T02长背压/flush；重复或倒序seq必须失败 | NOT IMPLEMENTED / NOT RUN |
| A03 | killed年轻指令零GPR/STORE/MMIO/CSR/BP侧效 | 3B最小Trap；4A/4B完整 | T03 ECALL+年轻SW/CSR/branch；错误侧效注入 | NOT IMPLEMENTED / NOT RUN |
| A04 | wb_we蕴含rd!=0；x0恒零，无假hazard | 3A-1/2 | T04写x0、读x0、双producer rd0 | NOT IMPLEMENTED / NOT RUN |
| A05 | 最新EX/MEM命中优先；未ready不得回退旧WB；ID对应EX RAW等待 | 3A-2；M/CSR到4A补齐 | T05双同名producer+未readyLOAD；错误选择注入 | NOT IMPLEMENTED / NOT RUN |
| A06 | valid&&!ready后地址/write/size/wdata/wstrb稳定直到握手 | 3A-3/3B；4B全链 | T06长背压+redirect/IRQ；改地址/数据注入 | NOT IMPLEMENTED / NOT RUN |
| A07 | owner请求至多一次、响应有主且一次；同拍旧A/新B归属独立 | 3A-3/3B | T07不同地址/数据LOAD交接；重复request/无主rsp注入 | NOT IMPLEMENTED / NOT RUN |
| A08 | STORE/MMIO/Stats/unknown请求首次呈现与fire均oldest+commit-qualified+live | 3B普通STORE；4A/4B设备补齐 | T08 MEM ECALL+EX SW，年轻Stats读；抢占端口注入 | NOT IMPLEMENTED / NOT RUN |
| A09 | 每owner真实write/FIFO-pop一次；rsp背压不重放 | 3A-3普通RAM；4B设备 | T09写与pop计数器，rsp_ready=0；重复WE注入 | NOT IMPLEMENTED / NOT RUN |
| A10 | killed纯读只drain；error不Trap，零WB/退休；旧PC/owner稳定 | 3B | T10 wrong-path LOAD success/error+背压；fault泄漏注入 | NOT IMPLEMENTED / NOT RUN |
| A11 | 最老fault抢年轻redirect/CSR/store；trap PC/cause/tval年龄正确 | 3B最小同步Trap；4A完整CSR | T11老LOAD error+年轻JAL/CSR；错误PC或优先级注入 | NOT IMPLEMENTED / NOT RUN |
| A12 | arch_next_pc匹配黄金退休；IRQ mepc=旧arch_next_pc，MRET准确；retire&&IRQ恒0 | 3A/3B仅适用子句；4A完整 | T12顺序/branch/Trap；T16 MRET/IRQ；同拍退休注入 | NOT IMPLEMENTED / NOT RUN |
| A13 | 老STORE/设备未完成时年轻LOAD零present/fire；SW[A];LW[A]读新值 | 3A-3/3B；4B设备 | T13同址/异址写后读+背压；允许年轻读抢口注入 | NOT IMPLEMENTED / NOT RUN |
| A14 | M仅消费匹配live generation一次；killed只drain，旧done不假完成，程序可推进 | 4A | T14快路径/sticky done；保守门先测DIV未启动；开放后测运行DIV kill+ISR MUL | NOT IMPLEMENTED / NOT RUN |
| A15 | IFepoch只stale IF；年轻redirect不kill老D/M，老LOADerror不被遮蔽 | 3B D子句；4A M；4B全配置 | T15 EX老LOAD+ID年轻redirect；用epoch kill注入 | NOT IMPLEMENTED / NOT RUN |
| A16 | pending同步/复核；retire与IRQ互斥；安全持续时次边沿take；CSR/MRET新MIE/PC下一边沿生效 | 4A | T16连续ALU IRQ、CSR开关、MRET后IRQ、held STORE；饥饿/旧CSR注入 | NOT IMPLEMENTED / NOT RUN |

每项负测必须使监视器/scoreboard明确失败；仅运行正例不足以证明断言接线生效。尚未实现测试可列计划/占位，禁止当作运行 PASS。完整 A12/A16 不在 3B 报 PASS，A14 的运行中 M 情况不能被保守禁止启动配置覆盖。

## 9. 后续验收边界

本轮允许标记 `SPEC FROZEN` 的对象仅是以上接口/owner/年龄/IRQ/预期断言合同经审查后的设计选择；它不升级为 `PARTIAL VERIFIED` 或 `IMPLEMENTATION PASS`。IF 七门、hazard 独立单元与 metadata 骨架测试分别记录实际 command/exit/transcript。

随后逐提交实现 ALU与退休 → 前递 → RAM访存/顺序 → 最小同步Trap → M/CSR/IRQ/MRET → Cache/Stats/observer。每个阶段只验已实现子句。CPU5 全回归、50 MHz 同频 A/B、STA与正式双种子板测完成前，无五级成绩或频率承诺；原三级正式成绩和位流作为独立回退基线保存。
