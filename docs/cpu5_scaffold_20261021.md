# CPU5 第一轮骨架：设计冻结、IF 复用与相关选择

2026-10-21。基线 `b3cb00dcba871ebf2275965be69ace13cfd395ed`。本轮执行规格 §10.1–2：冻结实现前合同，新建独立 CPU5 的接口与级间字段、metadata 推进框架、候选 IF 包装和最小 hazard。不是规格 §9 的 PLL 阶段1，也没有完成可运行的五级 ISA 核。

## 交付范围

- [设计合同](cpu5_design_contract_20261021.md)及配套 JSON：采样边沿、MEM 退休/WB 写回分工、64 位无回卷年龄、IF epoch 与 D/M owner 隔离、D 端年长优先及副作用授权、M generation/killed/drain、唯一 IRQ/退休真值表、A01–A16 的分阶段预期测试。
- `rtl/cpu5_top.v`：保留旧功能端口的名称/宽度，周期事件显式为十位；IF/ID 直接使用原 IF 的寄存输出和新侧带，不额外加一个 IF/ID 数据寄存拍。`pc_x/instr_x/valid_x` 来自 EX metadata，不再指向 IF/ID。
- `cpu5_pipeline_types.vh` 与 `cpu5_pipeline_skeleton.v`：四组包字段声明、ID/EX→EX/MEM→MEM/WB 的弹性 valid 推进、独立 WB 排空、按年龄冲刷。EX/MEM 保留预测 next-PC/taken/hit。IF 故障包在 MEM 停留，等待未来提交控制器。
- `cpu5_if_adapter.v`：原样实例化 `if_stage.v`，补充 seq/epoch、粘滞错误包、redirect 接受条件、已获授权的 BP 提交去重。
- `cpu5_hazard.v`：分别支持 EX 源选择和 ID 分支/JALR 的 EX RAW 等待；最新生产者未 ready 时阻止回退旧 WB。

**骨架只有 metadata 行为。** ALU、GPR、ISA 译码执行、架构退休、D/M owner、CSR/Trap/IRQ、十类计数和 SoC 集成均 NOT IMPLEMENTED。顶层 `wb_we/retire_valid/dmem_req_valid/trap_valid`、架构计数/周期事件均固定零；UART idle、GPIO无驱动。debug WB release 只是包释放，绝不是退休或 CoreMark 成绩。顶层未被加入任何正式 PDS/板顶；`SKELETON_ONLY=1`、外部 I 端是当前编译边界。

## 已运行的局部测试

| 范围 | 实际结果 | 不能替代的验收 |
|---|---|---|
| IF 七项复用门 | ModelSim 正例 121 检查通过；独立公开端口账本 457 检查，16 req/16 rsp，5 包转移（含1故障），7 redirect，4 BP update，1 次旧响应＋新请求同拍 | 老 MEM 优先、真实退休授权、错误路径 BP 零训练仍需未来 commit_ctrl 集成测试 |
| IF 序号耗尽 | 全1值保留为终止标记；故意设置尾部序号，明确检查 raw slot 仍有效时公开 ifid_valid 已为0且不再接受响应；出现一条预期 fatal，组合脚本退出0 | 不是正常继续执行或保证最后包退休；必须 reset |
| hazard 两种模式 | 442,418 组向量，1,769,672 次逐源比较，0 error/warning；六种真实 RTL 突变全部退出1被拒绝 | 实际流水旁路接入、LOAD/M/CSR ready、branch 解析 A/B 尚未实现 |
| metadata pipeline | 29 接受 = 21 debug release + 5 年龄 kill + 3 reset discard；背压期间整包稳定；77 次级间字段检查，WB hold 7次；旧 WB 可在 MEM wait / 年轻 flush 时独立释放 | 不验证架构指令语义、GPR、访存、异常退休 |
| top 接线 | EX/ID 分支参数两种 elaboration；正常12 req/12 rsp/12 debug release；错误场景4个老包释放后，seq4/PC0x10 fault 留在 MEM；所有架构输出为0 | 不是五级运行 C 程序或指令退休回归 |

骨架测试包含 32 位序号边界 `0xfffffffe → 0xffffffff → 0x1_00000000`，确保年龄比较没有截断；输入 epoch 每个包不同，不参与 EX/MEM 存活判断。`flush_cut_seq` 是第一条被杀的序号：branch 为 source+1，Trap 为 source，IRQ 为首条未退休；被 kill 的上游 IF/ID 也必须由同一 flush 协议撤销，单纯 ready=0 不会消费它。正常流、hold/气泡、年龄 kill、故障 MEM 停留、带包 reset 均由独立队列核对。

骨架另做三项真实故障注入：年龄比较截为32位、WB错误重复释放、允许故障包进入WB，均被原测试拒绝（退出1，其中截龄通过队列无法排空触发 timeout）。原版正例进程退出0，编译/仿真0 error/warning。负例的 fatal/非零码是预期拒绝，不能和原版失败混算。每个负例保留独立目录、原始坏 RTL、DO、trace 和日志，避免覆盖正例 trace。

IF 初次试验曾因 TB 没在错误响应前及时阻塞 ID，导致 G4 场景未成立；仅修正驱动时序，保留初始失败，不放宽 RTL/检查门。骨架首次启动日志目录尚未创建，未进入仿真；之后补齐目录。代码审查又收敛了终止态重复 valid、预测侧带贯穿、64位年龄边界及正负例 trace 隔离，最终证据对应当前源 SHA。

## 设计冻结的关键选择

设计合同状态为 **SPEC FROZEN（仅接口/owner/IRQ/预期断言设计）**。A01–A16 的完整 CPU5 实现和验收仍逐项 NOT IMPLEMENTED / NOT RUN；IF/hazard/metadata 的局部通过只记 PARTIAL VERIFIED。

IRQ 本拍资格使用旧 arm 和本拍前已提交 CSR；若本拍正常退休，`arm_next` 用此次退休后的 CSR 和同步 pending 生成。这样 CSR 开中断或 MRET 在 T0 退休，T1 能按新 MIE/PC 取 IRQ；若 IRQ 早已 armed+eligible+safe，则优先于尚未退休的 CSR-disable。IRQ 与普通退休同拍互斥，`mepc=旧 arch_next_pc_q`。15 个纯设计参考案例检查通过；没有 IRQ RTL 仿真，不能把它写成 A16 PASS。

D 端首版 `held > oldest MEM > eligible EX RAM LOAD`；老 STORE/MMIO/Stats/未知事务未完成时年轻 LOAD 零呈现。M 首次接入采用保守的老 MEM 未决则不 start，仍保留 owner/generation/killed/drain，不以 busy 或旧 sticky done 冒充新完成。分支解析参数保持可切换；默认 EX 只为骨架占位，不冻结最终性能方案。

## 复跑

使用 ModelSim 10.6e，在工程根目录，SystemVerilog 编译选项为 `vlog -sv`：

```powershell
& 'D:\modeltech64_10.6e\win64\vsim.exe' -c -do run_cpu5_if_adapter.do
python -B tools/analyze_cpu5_if_adapter.py
& 'D:\modeltech64_10.6e\win64\vsim.exe' -c -do run_cpu5_hazard.do
python -B tools/verify_cpu5_scaffold.py
```

最后一个命令运行原版 pipeline/top，随后运行三个必须失败的骨架突变；日志在 `build/cpu5_s1_scaffold/`。hazard 的坏 RTL/失败日志在冻结证据中保留，正常 DO 默认只编译原版。

[长期证据](evidence/cpu5_scaffold_20261021/README.md)含运行日志/CSV、SHA、契约参考检查与独立集成核对；完整源归档和 WLF 保留在本机 `build/verification/cpu5_scaffold_20261021/`。原三级与已有工作区文件共766份逐字节保护检查通过。没有改旧 RTL、约束、固件或正式位流；没有新 P&R、板测、资源数或性能/频率承诺。

下一步单独实现 3A-1：整数 ALU、GPR 与 MEM 架构退休，先按 ADD/SUB/SHIFT/x0 逐退休 PC/instr/rd/value 对账，再接真实相关和访存。原三级核继续作为回退基线。
