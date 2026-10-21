# CPU5 阶段 0：profiler 存量与语义映射

日期：2026-10-21。只读核对主工程 `D:\FPGA\riscv_3stage`，HEAD `1b7cb1251f5ff589ab1a6be8537b3362cc3f3a73`。规格 v0.3 SHA256 `bc4898b62a77fe2d9382ee1111dbe63a13bd4420936efba1756fb3fa090e8d6f`。

**本报告只完成 E 的源文件清点与迁移设计草案。CPU5 RTL／probe 均 NOT IMPLEMENTED，CPU5 测试均 NOT RUN；不宣称 SPEC FROZEN、PARTIAL VERIFIED 或 IMPLEMENTATION PASS。没有启动 ModelSim、构建、综合、P&R、下载或 Git 写操作。**

## 文件身份与来源

完整原始 SHA256、Git HEAD blob、最近提交、工作区状态、行号锚点和宏展开见同目录 `profiler_inventory.json`。raw SHA 和 LF 规范化 SHA 分列，避免把 EOL 差异误认为逻辑差异。untracked 文件仅是本机证据，不自动拥有可复现的 Git 来源。

| 组 | 实际文件 | 来源／状态 | SHA256 |
|---|---|---|---|
| d1_m1_m2 | `run_coremark_d1_measure.do` | tracked; clean | `febdf03c79e3c0ca0a023da8ff54c24435cef04e3f4b11301e194be43de5472e` |
| d1_m1_m2 | `tb/coremark_d1_measure_tb.v` | tracked; clean | `f84411cd94d337d99876ede6bfe861a99146f92d83f1f89270b4546cf5eb5760` |
| d1_m1_m2 | `tools/analyze_d1_measure.py` | tracked; clean | `c393007de9066af3014adb0816741504f7a65d967f1b202277e1dd94aa0cdc93` |
| synthetic_axi_write | `run_axi_write_profile.do` | tracked; clean | `fb86bb51d001a86323f00a7754e13a99a61a19a66658030fcbfe1b7cddd9140d` |
| synthetic_axi_write | `tb/axi_write_profile_tb.v` | tracked; clean | `6a48f60739f1f5062fe3b20c8e64f82939a48ed8e27409037667106aabb8ecfd` |
| synthetic_axi_write | `tools/analyze_axi_write_profile.py` | NOT FOUND | `—` |
| synthetic_axi_write | `docs/axi_write_profile.md` | tracked; clean | `242acac9ec87c7b4316451a0187737ff17397441d291c5898a7a5e38df3127ad` |
| real_coremark_axi_write | `run_coremark_axi_write_profile.do` | untracked | `dd989e7d3f570d094a11bd64e42534891f1c086b8ce599551f2b21cc6c3077dd` |
| real_coremark_axi_write | `tb/coremark_axi_write_profile_tb.v` | untracked | `25535286471bb0dae1cdaf2d15db820cbcf0bb0e904c7560b86aca31c17c60f7` |
| real_coremark_axi_write | `tools/analyze_coremark_axi_write_profile.py` | untracked | `e7937e4f66f5d3c09178f7cd7c1a1b43cf328f651d77a50d5c228fa04c2f6a1a` |
| real_coremark_axi_write | `docs/coremark_axi_write_profile.md` | untracked | `bbd0e25eb0e15feb72188893087e475550e54a7f2f8c14300d53fee3a66c5878` |
| d0_native_write | `run_coremark_d0_measure.do` | tracked; clean | `0ecc656a91331af3bda45383ff84af58e7bc9baa6c24bd40583ddb9ee34e89af` |
| d0_native_write | `tb/coremark_d0_measure_tb.v` | tracked; clean | `aa4e95a282752b983605c3ac0c24bcd4bb807cd5aa0661e56128d3749597d173` |
| d0_native_write | `tools/analyze_coremark_d0_measure.py` | tracked; clean | `847799e4f24263ee9a1ff1faede35a615d20ee4f90f9b4821444b7352a666ca8` |
| cycle_profile | `run_cpu_cycle_profile.do` | tracked; clean | `d071d1c4e71312cfa82b7230c7bf48e5eb5d56fcdabfb7cf983abdb110e2268c` |
| cycle_profile | `tb/cpu_cycle_profile_tb.v` | tracked; clean | `676f708c77347ffa6b68ae0ccc5a7eee6e93b919bbe14123c047b014377ecfe6` |
| cycle_profile | `docs/cycle_profile.md` | tracked; clean | `3d425ebfbb6e4d7a0d5ab5b5234f965a4b3f74d2b4557b4d8fa950c3941516ee` |
| workload | `run_coremark_m.do` | tracked; clean | `3c9ddf0b374c74d2cddb826a9877fd7616562c016e4e93fa3dda6377b729218f` |
| workload | `tb/coremark_axi_tb.v` | tracked; M tb/coremark_axi_tb.v | `d623e1daf08c35a39a73387375890e03a74940fda7c5e5a2af91ee3369db12fc` |
| workload | `tb/coremark_d0_workload_tb.v` | tracked; clean | `dcb7b94e0a43cd3258d3b7fd05f013506111c7fe1704868afbb26e0ac6a6d0fa` |
| workload | `tools/coremark_axi_contract.py` | tracked; clean | `6af891479986f4595f5b64867da3b4d8eaffdc6090778b464fb151d4ce26dcfe` |
| workload | `tools/regression_suites.json` | tracked; M tools/regression_suites.json | `88334d3eab21b9a83bbbc89bdf827777fdead493c3598dbb48335e81ebd27101` |
| semantic_sources | `rtl/cpu_top.v` | tracked; clean | `80355b3dbfa93d3f22508dafe38737657172731aec2be3f1674ff674bcbf3a6b` |
| semantic_sources | `rtl/if_stage.v` | tracked; clean | `c2dd341e85cd38a76f48ad495c5e5c5d4349854d293fe2e1779b9d783db2dbec` |
| semantic_sources | `rtl/branch_predictor.v` | tracked; clean | `27d6ab676db29b48a902e7ae68775e736e7be354b4c61dba495353fd537df578` |
| semantic_sources | `rtl/soc_axi_lite_top.v` | tracked; clean | `225b0b69b0cd2b4b29cd17e064fef10bd4df4dd9c8c514c34e8c9195344acc76` |
| semantic_sources | `rtl/soc_coremark_axi_top.v` | tracked; clean | `6ae296042f46c3268ec41bf1eca71e315a1b2338f757b298d948ec2851fc8d3d` |
| semantic_sources | `rtl/axi_lite_coremark_stats.v` | tracked; clean | `94530071a9b08921e09238712053891ecae1c9fc5b1d843f828588e8580ec439` |
| semantic_sources | `rtl/machine_timer.v` | tracked; clean | `3d3a4ae9e6b47088f9ed8ad05d906aa608148cb0c9c250fa26c736d88afe45c5` |
| semantic_sources | `rtl/rv32m_unit.v` | tracked; clean | `e496552f58197203697e4589ffe0bedca85178a7806ad732e18888c677e1638c` |
| semantic_sources | `rtl/data_cache.v` | tracked; clean | `291e851888e7cd56787ad73ee7af095a5c2010f3edaea716da76c849a7fb036b` |
| semantic_sources | `rtl/dmem_region_router.v` | tracked; clean | `3277da11f17a1a1d2ae6a9475934d5c2b2123a4ebb1b869fa0c02b1a44f452ba` |
| semantic_sources | `rtl/soc_data_mem.v` | tracked; clean | `93c6dc2089ca9ed3dfff95079463a82e7b57d4a3216e3becb1bf57d8b8551d25` |
| semantic_sources | `software/coremark_port/core_portme.c` | tracked; clean | `3e61e45fcdb3e1b18f466251a60bf7a77933e61422a141b2d079059a49ce124c` |
| semantic_sources | `software/coremark_port/core_portme_axi.c` | tracked; clean | `78d5f38c29ef241b230f378884eff51d7589b3d2970ea48d00483eaee8143c4f` |
| semantic_sources | `software/coremark_port/coremark_axi_stats.h` | tracked; clean | `964b888e1f32cba9c58eb1de3f39cff9c7434366b860a2dcf85e8b6e815d718c` |
| semantic_sources | `software/timer.h` | tracked; clean | `974fadf5ac88dcabd6c76319303026436262845be62c0ca08c3725601ca71338` |
| cpu5_planned_only | `rtl/cpu5_top.v` | NOT IMPLEMENTED | `—` |
| cpu5_planned_only | `rtl/cpu5_cycle_profile.v` | NOT IMPLEMENTED | `—` |
| cpu5_planned_only | `rtl/axi_lite_coremark_stats5.v` | NOT IMPLEMENTED | `—` |
| cpu5_planned_only | `rtl/cpu5_m_owner.v` | NOT IMPLEMENTED | `—` |

## 生命周期与现有 CSV 合同

- **D1：仍固定两次 START。** TB `133–156,299–301` 和 analyzer `73–79` 都硬性要求 `raw=2, selected=1, epoch=2, STOP=1, crossings=0`。当前并未泛化。本轮不修改历史 D1。`M1_CAP=40, M1_SAVE=7, M1_LIMIT=14` 是旧写等待投射参数，不适用于把 D0／CPU5 净收益直接读作写缓冲收益。
- **D0：通用最后 START。** analyzer 第 28 行要求 `raw>=1 && selected==1 && epoch==raw && stop==1`，第 29 行拒绝 boundary/error/cancel；TB 第 31、54–65 行相应实现。D0 固定时序验收还要求 STORE 两拍、CPU response 与 retirement 同边沿（TB 108–117；analyzer 40–42），这些是旧实现特性，不能迁为五级安全不变量。
- **真实 CoreMark AXI 写通路：通用最后 START。** TB 295–311、analyzer 122–127 实现最后代次选择；CSV 保留每笔 `window_epoch`，只汇总选中 epoch。该组四个文件（runner/TB/analyzer/docs）当前均为 untracked，已记录 raw SHA；原 ZIP 缺它们与当前工作区存在并不矛盾。
- **独立十场景 AXI 写通路：没有找到独立 Python analyzer。** 场景/事务/27 个指标/错误取消与加总检查内建于 TB，runner 只检查 TB 完成标志。其 `epoch` 是 reset 启动代次，不是 CoreMark START 银行代次。不能把真实 CoreMark analyzer 套上其 CSV。
- D1 输出 `build/d1_measure_<profile>_window.csv`（key,value）和 buckets（key,count，gap 0..40 加六个 M2 桶）；D0 输出 transactions/window；真实 CoreMark 写通路输出 transactions/summary/window；独立 AXI 场景输出 transactions/summary。实际列头逐一自动摘录于 JSON 的 `csv_literal_headers`。
- D1 key/value 及桶 CSV 没有显式 schema 列；D0/真实写通路 analyzer 的 JSON `schema_version=1` 不是硬件 schema3 或周期 profile schema1。迁移必须分开命名三个层面的版本。不能仅改 prefix 后保留不同语义的旧列名。

## 边沿与窗口：避免一拍错账

设 E 是物理 posedge 编号。PRE-NBA 是该边沿之前的稳定组合／寄存值；POST-NBA 为现有 TB 用 `#1` 观察更新后的状态。

1. `mem_start_x`、总线 req/rsp fire、真实 RAM WE、BP resolve：PRE-NBA 采样。这些分别是发起、握手、副作用和完成事件，不能互相替代。
2. `perf_cycle_events`：CPU 在该边沿根据 PRE-NBA 条件注册新事件，POST-NBA 才看见归属 E 的值。原 stats 在 E 使用旧事件形成 `profile_next`，START/STOP 锁它以对齐 PRE-NBA `cycle_count`。
3. 所以 S=START、T=STOP 的计数差，物理阻塞边沿是 `[S,T)`；在 POST-NBA 采新事件同样取 `[S,T)`；若 PRE-NBA 直接采旧注册事件，必须取 `(S,T]`。两种不能混用。D1 BP 是当前 PRE-NBA resolve，硬件锁 BP pre-counter，因此 BP 事件取 `[S,T)`；不存在把所有注册字段统一移一拍的万能规则。
4. `retire_valid` 与 `wb_pc` 同一边沿注册。现有写观察器 POST-NBA 看见 E 完成的指令；新 RAW 观察器若 PRE-NBA 采它们，看见的是 E-1 完成的指令，必须显式标注 completion edge／观察延迟并绑定 PC，不能用实时 `instr_x`。`instret_count` 再根据 PRE-NBA `retire_valid` 增加，端点对账须保持此合同。
5. mtime 每拍 NBA 增加；端点接受读时取 pre-increment 值，固件 high/low/high 在三个不同被接受的读边沿取数，溢出则重试。START 在计时读取前，STOP 在计时读取后，故 `counter_cycles` 与 `raw_ticks` 允许有边界开销，不能强制相等。

## 旧层次到 CPU5 的字段合同草案

下列新名字全部是**规划**；首次实现 patch 还需锁定具体端口、宽度、owner 字段、边沿、寄存延迟与 schema。

### S01：`D1_CPU.mem_start_x && D1_CPU.is_store_x && !D1_CPU.mem_req_mmio`

- 实际层次：`workload.dut.u_core.u_cpu`；来源：`tb/coremark_d1_measure_tb.v:68-70; rtl/cpu_top.v:1249-1259`。
- 指令年龄：current valid EX instruction, before its transaction is latched; not a D request handshake。
- 采样：posedge PRE-NBA。窗口：last START inclusive, STOP exclusive [S,T); D1 fixed raw=2, selected=1, epoch=2。
- 输出意义：M1 gap buckets, next non-local EX memory launch。
- CPU5 拟探针：`cpu5_mem_launch_valid/pc/seq/is_store plus a separately defined launch stage; or cpu5_d_req_fire+owner_is_store with a NEW metric/schema`。
- 兼容结论：ADAPT REQUIRED; CPU5 MEM STORE cannot be paired with EX is_store; moving launch to handshake changes measured S。**CPU5 NOT IMPLEMENTED / NOT RUN。**

### S02：`D1_CPU.bp_resolve_valid && D1_CPU.bp_predictable_x`

- 实际层次：`workload.dut.u_core.u_cpu`；来源：`tb/coremark_d1_measure_tb.v:70-71,225-245; rtl/cpu_top.v:794-805,884-889`。
- 指令年龄：completed architectural instruction; predictable set is conditional branch OR JAL, excludes JALR。
- 采样：posedge PRE-NBA, same combinational event as counter update; counter values before increment。窗口：[S,T), endpoint pre-counter differences must reconcile。
- 输出意义：e_resolved / direction error decomposition / hit and relearn / separate JALR count。
- CPU5 拟探针：`cpu5_bp_resolve_commit, owner seq/PC/op, prediction metadata, direction/target/mismatch and eligible-set flags`。
- 兼容结论：ADAPT REQUIRED; retain eligible set and retirement ownership; no speculative younger training。**CPU5 NOT IMPLEMENTED / NOT RUN。**

### S03：`D1_IF.prediction_hit_x/prediction_taken_x; D1_BP.update_match`

- 实际层次：`workload.dut.u_core.u_cpu.u_if_stage[.g_branch_predictor.u_branch_predictor]`；来源：`tb/coremark_d1_measure_tb.v:19-21,228-241; rtl/if_stage.v:81-96; rtl/branch_predictor.v:83`。
- 指令年龄：IF-latched prediction metadata transported with the same EX instruction; update_match is current predictor table match at update。
- 采样：posedge PRE-NBA。窗口：[S,T), gated by S02。
- 输出意义：M2 miss/hit-wrong-direction/relearn buckets。
- CPU5 拟探针：`retired owner prediction_hit/taken and commit update_match metadata`。
- 兼容结论：ADAPT REQUIRED; IF/ID live metadata must not be combined with MEM control instruction。**CPU5 NOT IMPLEMENTED / NOT RUN。**

### S04：`bp_resolve_valid && bp_next_mismatch_x / bp_mispredict_count`

- 实际层次：`workload.dut.u_core.u_cpu`；来源：`rtl/cpu_top.v:794-807,884-889`。
- 指令年龄：all completed supported instructions with actual next PC, not just predictable branch/JAL; JALR mismatch can count。
- 采样：event PRE-NBA; counter increment visible POST-NBA。窗口：event [S,T) agrees pre-counter STOP-START; post-NBA registered trace must align owner。
- 输出意义：redirect events distinct from redirect_wait cycle count。
- CPU5 拟探针：`cpu5_bp_mispredict_commit with opcode/PC/seq; optional speculative redirect issue separate`。
- 兼容结论：ADAPT REQUIRED; preserve all-instruction mismatch vs control-only R denominator distinction。**CPU5 NOT IMPLEMENTED / NOT RUN。**

### S05：`retire_valid + wb_pc (+wb_rd/wb_data/wb_we)`

- 实际层次：`workload.{retire_valid,wb_pc} / workload.dut.u_core.u_cpu`；来源：`rtl/cpu_top.v:1543-1575,1628-1660; tb/coremark_d0_measure_tb.v:103-117; tb/coremark_axi_write_profile_tb.v:392-435`。
- 指令年龄：instruction completed at this edge; registered retire_valid and WB metadata correspond after NBA。
- 采样：POST-NBA #1 in existing STORE observers; PRE-NBA sampling observes previous edge completed instruction, valid if deliberately aligned; instret_count increments from PRE-NBA retire_valid。窗口：do not mix physical completion [S,T) with delayed observation without explicit edge/owner alignment。
- 输出意义：STORE retirement timestamp; new RAW trace must PC-decode same ROM and must not substitute live instr_x。
- CPU5 拟探针：`cpu5_mem_commit_valid plus commit PC/instr/seq/rd/value, and separately WB-stage write; explicit output latency`。
- 兼容结论：ADAPT REQUIRED; MEM retirement may precede WB GPR write, retire_valid is not wb_we。**CPU5 NOT IMPLEMENTED / NOT RUN。**

### S06：`dmem_req_valid&&ready / bridge_req_valid&&ready / dmem_rsp_valid&&ready`

- 实际层次：`workload.dut.u_core.*`；来源：`tb/coremark_d0_measure_tb.v:79-101; tb/coremark_axi_write_profile_tb.v:330-369; rtl/soc_axi_lite_top.v:167-220`。
- 指令年龄：current one-outstanding transaction owner, descriptor frozen from EX launch。
- 采样：posedge PRE-NBA。窗口：transaction epoch/launch membership; boundary-crossing checks; response/retire timestamp separate。
- 输出意义：cpu_accept/backend_accept/cpu_response; AXI timestamp chain only when AXI backend selected。
- CPU5 拟探针：`cpu5_d_req_fire, cpu5_d_rsp_fire, separate old rsp_owner/new req_owner seq/PC/op/class; killed/drain flag`。
- 兼容结论：ADAPT REQUIRED; same-cycle A response/B request must not use one live owner or EX PC。**CPU5 NOT IMPLEMENTED / NOT RUN。**

### S07：`actual BRAM mem_we / AXI RAM u_data_mem.we; AW/W/B handshake and first VALID`

- 实际层次：`D0_RAM=workload.dut.u_core.g_d0_bram.u_ram; CMW_RAM=workload.dut.u_ram; synthetic case.ram`；来源：`tb/coremark_d0_measure_tb.v:89-105; tb/coremark_axi_write_profile_tb.v:342-403; tb/axi_write_profile_tb.v:390-426`。
- 指令年龄：irreversible write belongs to accepted transaction descriptor; AW/W pairs timestamp=max(AW,W)。
- 采样：WE and handshake PRE-NBA; RAM readback and first VALID POST-NBA #1。窗口：native D0 forbids ordinary RAM leak to AXI; synthetic epochs are reset epochs, not START banks。
- 输出意义：one physical effect per store, byte-mask verification, additive vs diagnostic stages。
- CPU5 拟探针：`backend effect probe plus owner identity/class; younger requests require MEM oldest authorization`。
- 兼容结论：backend physical probes conditionally reusable if backend unchanged; timing equality/CPU owner adapters must change。**CPU5 NOT IMPLEMENTED / NOT RUN。**

### S08：`stats_arvalid&&stats_arready at 0x30000000 / 0x30000004`

- 实际层次：`workload.dut.* and workload.dut.u_stats`；来源：`rtl/axi_lite_coremark_stats.v:122-180; software/coremark_port/core_portme_axi.c:28-41,66; tb/coremark_d0_measure_tb.v:54-65`。
- 指令年龄：device read has snapshot side effect; AR acceptance edge, not R response or retirement。
- 采样：posedge PRE-NBA at AR; snapshot registers written NBA。窗口：portable_init ID read is a real START; later START re-arms and supersedes bank; last START selected; STOP exactly once。
- 输出意义：frozen cycle/instret/cache/BP and cycle-profile banks。
- CPU5 拟探针：`MEM-authorized STATS transaction acceptance + snapshot event IDs and aligned counters; independent stats5/schema`。
- 兼容结论：address/effect contract may survive; CPU5 timing/counter ABI must be revalidated; never EX speculative stats read。**CPU5 NOT IMPLEMENTED / NOT RUN。**

### S09：`perf_cycle_events[5:0] and profile_next[0:5]`

- 实际层次：`workload.dut.u_core.u_cpu / workload.dut.u_stats`；来源：`rtl/cpu_top.v:1587-1624; rtl/axi_lite_coremark_stats.v:65-76,151-152,179-180; tb/coremark_axi_write_profile_tb.v:280-284,392-429`。
- 指令年龄：one registered attribution per counted physical CPU edge; six-class one-hot, includes M waits in work_other。
- 采样：CPU computes pre-edge predicate -> event POST-NBA; stats consumes old registered event with profile_next at same snapshot edge。窗口：physical attribution edges [S,T) correspond to PRE-NBA registered-event samples (S,T]; POST-NBA observer samples [S,T)。
- 输出意义：six counters sum to cycle_count delta; event counter NOT additive with nonexclusive BP/M/retire events。
- CPU5 拟探针：`cpu5 ten-bit registered main attribution, hardware schema4/profile schema2 (planned), explicit count enable and snapshot alignment`。
- 兼容结论：NOT BINARY COMPATIBLE; dedicated stats/firmware/guard/analyzer; do not silently truncate high bits or require other==instret。**CPU5 NOT IMPLEMENTED / NOT RUN。**

### S10：`timer_mtime / mem_req_fire && timer_read_hit_x / load_mmio_data_q`

- 实际层次：`workload.dut.u_core.u_cpu.g_machine_timer.u_timer (generate instance verify source) and MMIO endpoint descriptor`；来源：`software/timer.h:15-24; software/coremark_port/core_portme.c:383-391; software/coremark_port/core_portme_axi.c:28-41; rtl/cpu_top.v:1175-1193,1272-1294,1414-1418; rtl/machine_timer.v:24-43`。
- 指令年龄：actual LOCAL MMIO endpoint request owner; hi/lo/hi are separate accepted reads, low captures PRE-increment mtime and retry on high rollover。
- 采样：endpoint fire/read data PRE-NBA; load_mmio_data_q captures same edge NBA; mtime increments NBA。窗口：START before mtime sample and STOP after mtime sample; counter_cycles can exceed raw_ticks by boundary overhead, do not equate them。
- 输出意义：raw_ticks/seconds vs frozen counter window; workload checks actual high-low-high samples。
- CPU5 拟探针：`MEM-authorized local endpoint fire + read/write descriptor, pre-pop UART head/data capture; mtime and stats remain separate devices`。
- 兼容结论：timer helper/endpoint behavior reusable if contract unchanged; five-stage timing and UART pop require new tests。**CPU5 NOT IMPLEMENTED / NOT RUN。**

### S11：`m_start_x/m_complete_x/m_wait_x + instr_x[14:12]`

- 实际层次：`workload.dut.u_core.u_cpu[.g_m.u_muldiv]`；来源：`rtl/cpu_top.v:996-1016; rtl/rv32m_unit.v`。
- 指令年龄：held EX M owner in three-stage CPU; start/complete events distinct from actual wait cycles; sticky unit done。
- 采样：posedge PRE-NBA for control event; done/result POST-NBA from unit then CPU completion at later edge。窗口：count start/complete/wait separately and record boundary-spanning owner; not equal to all work_other-retired by assumption。
- 输出意义：current profiler set has no complete standalone MUL/DIV measurement export; planned observation。
- CPU5 拟探针：`m owner valid/seq/pc/op/killed/start accepted/result consumed and independent mul/div wait/complete`。
- 兼容结论：ADAPT REQUIRED; killed owner drains, unit resource busy and architectural blocking are different。**CPU5 NOT IMPLEMENTED / NOT RUN。**

## Workload 变体与可复用边界

- `tb/coremark_axi_tb.v:59–65` 是 AXI workload，没有传 `ENABLE_D0_BRAM`，只换配置宏不等于 D0。M/D0 应使用 `tb/coremark_d0_workload_tb.v:62–69`，该处明确连接 backend 和 ENABLE_M，`run_coremark_m.do` 也使用它。D0 observer 第 12 行实例化的正是 D0 workload。
- D1/真实 AXI 写观察器的 `workload.dut.u_ram` 是 AXI RAM；D0 的 RAM 是 `workload.dut.u_core.g_d0_bram.u_ram`。原生 BRAM流量无 AW/W/B，不得编造 12 段 AXI 时间戳。
- 独立 AXI 案例使用 `axi_write_profile_tb.<case>.cpu`、`.ram` 及本地 cq/bq/AXI wire；不采用 D1 宏。现有端点协议断言可在后端不变的条件下复用，但 CPU retirement/launch 固定延迟必须变更。
- 建议保留旧 TB 与 analyzer 文件，CPU5 用新 adapter+新 schema。M1 若从 EX launch 改为 MEM req acceptance，是新指标而非原始 gap S 的直接延续；比较前需两种采样同时记录以证明定义。BP 预测元数据必须跟随退休控制指令，不能读取当拍 IF/ID 的预测作为 MEM 指令属性。

## CPU5 后续必须执行的合同测试（本轮均 NOT IMPLEMENTED / NOT RUN）

- **E-T01** Three raw START triggers -> final epoch selected; one raw START accepted; STOP=1; active STORE crossing START/STOP rejected; no combined reset epochs.
- **E-T02** At S/T inject distinct pre-edge and post-edge BP/retire/profile events; prove physical [S,T) and delayed registered events (S,T] with integer endpoint ledgers.
- **E-T03** MEM older STORE with EX younger ALU or STORE: launch/op/PC/seq stay same owner; never combine MEM mem_start alias and EX is_store.
- **E-T04** RSP(A)+REQ(B) same edge, A error/kill and B ready/backpressure: old response and new request carry distinct owners, each completes once.
- **E-T05** EX older RAM LOAD + ID younger redirect: D owner survives fetch-epoch change; older LOAD error still traps; wrong-path younger LOAD drains without Trap/WB.
- **E-T06** Retire instructions with rd=x0, STORE, CSR and M; one retire pulse independent of wb_we; MEM retirement vs later WB observed with explicit latency.
- **E-T07** MUL vs DIV/REM including divide-by-zero, INT_MIN/-1, sticky done, killed DIV then ISR MUL: per-owner start/complete/wait and drain partition.
- **E-T08** BP branch/JAL/JALR/non-control stale prediction cases: eligible-set counters, mismatch events and redirect wait cycles separately reconciled; no killed younger training.
- **E-T09** UART RX pop/head capture and every MMIO write enable at one authorized endpoint edge; local timer high-low-high rollover; STATS read never speculative.
- **E-T10** Ten-class one-hot/count-enable, reserved-address collision negatives, schema4/2 rejection by old guards and old six-class firmware unchanged.
- **E-T11** Native D0 RAM write effect readback vs AXI write effect readback: no invented AXI phases on BRAM traffic; latency equality constraints versioned for CPU5.
- **E-T12** Dynamic RAW shadowed writer, both-source overlap, x0 and unused operands: distance2 is exact closest-writer distance only, never producer-unready inference.

## 本轮边界与验收

本轮只读扫描及证据生成脚本成功执行，audited_files_unchanged_at_end=true，Git HEAD 与 status 在本脚本前后相同。该检查证明本次清点过程未改变被审文件，并不替代父任务对整个工作区的冻结核验。所有历史文档中的 PASS 都是原记录，本次没有重新运行它们。CPU5 的 probe、hazard CSV、十分类实测、A01–A16、PLL、ILA、STA 均未在本子任务实现或运行。
