# CPU5 3A-2：整数 ALU 前递子集

2026-10-21，基线 `c77b7ec8e70c4b06d2121856670231a74f15e799`。本轮接入真实 EX/MEM→EX、MEM/WB→EX 与 WB→ID，状态为 **PARTIAL VERIFIED：3A-2 整数 ALU 子集**。实际 LOAD-use、分支/JALR-use 尚未实现，不能宣布规格 §9 的完整3A-2或A05验收通过。

## 实现

在 `cpu5_alu_pipeline.v` 内接入已有、原样保留的 `cpu5_hazard.v`。每个真实源独立选择：x0恒零，最新 EX/MEM 写者优先，其次已退休 MEM/WB，最后 ID 保存值。生产者的命中资格与 ready 分开判断，最新命中未 ready 时阻塞 EX，不能回退到老 WB。MEM 退休也要求自身 `result_ready`，防止未完成结果提前进入 WB。

WB 数据已经生成，即使 `wb_ready=0` 被背压持有也可旁路。ID 在采样边沿保存 WB→ID 的值，解决 WB 同边沿写入并排空后消费者仍保存旧RF值的问题。EX 持有期间按源保存已取得的前递值；某个源被阻塞时，另一可用源仍保存，避免其 WB 生产者先排空后丢值。不能用整体 stall 阻止两个源的所有保存。

LUI的零输入、AUIPC的PC、立即数选择位随ID/EX保存，避免把指令中相同位置的位误当实际GPR依赖。killed MEM不参与前递；已退休WB不受年轻冲刷取消；fetch epoch不参与EX/MEM生产者存活判断。MEM唯一退休、WB后续物理写回及x0禁写的合同不变。

两个模块新增 `ENABLE_FORWARDING` 参数，默认0保留3A-1可复跑的保守参考；新测试明确启用：

```verilog
cpu5_top #(.SKELETON_ONLY(0), .ENABLE_FORWARDING(1)) ...;
```

默认 `SKELETON_ONLY=1` 仍为metadata骨架。没有将CPU5加入SoC、板顶或正式PDS工程。

## 实测 A/B

两模式使用同一550条机器码、相同取指端点条件，逐条退休七字段及最终GPR一致；周期为包含启动和停止检查开销的定向测试周期，不是CoreMark或正式测量窗口。

| 端点条件 | 保守模式总周期 | 前递模式总周期 | 保守RAW等待 | 前递RAW等待 |
|---|---:|---:|---:|---:|
| 无额外取指等待 | 1206 | 559 | 647 | 0 |
| 变长取指等待/背压 | 1933 | 1933 | 296 | 0 |

第一组减少647拍（53.65%）；第二组没有总周期收益，取指等待掩盖了RAW等待的消除。不能把第一组百分比外推到CoreMark，也不能声称所有配置提速。分析器对两组要求不退化，并仅对无等待端点要求严格改善。

## 回归与拒绝测试

- **50个top场景**：48个前递配置（两种正常端点、IF错误、45个未支持编码停止）加2个同程序保守基线。独立第二套机器码解释器核对2293退休=2293个WB包，其中2153次物理GPR写、140个x0禁写包；PC/instr/seq/rd/value/writes/nextpc、instret、最终GPR、metrics全部闭合。
- **13个独立控制场景**：连续9条ALU依赖无插泡；最新同rd MEM优先；双源分别取MEM/WB；WB同拍ID旁路；EX/MEM/WB背压；生产者排空后的EX值保存；两种partial-blocked镜像；x0、LUI/AUIPC/移位选择；64位年龄边界和跨epoch；人工unready恢复。44退休=44 WB消费、43物理写；46次ID接受中2个未退休包被flush。
- **7个真实坏RTL全部退出1被拒绝**：去掉WB→ID、去掉EX保持保存、两个源错误共用整体stall保存门、仅rs1错误依赖整体stall、WB ready误作数据ready、最新MEM未ready时回退WB、旧WB覆盖新MEM。均为运行断言拒绝，编译成功；坏源和日志单独保存。
- **5个坏CSV全部拒绝**：WB值错、缺WB、instret错、前递模式RAW非零、保守基线RAW为零。没有修改良好CSV或伪造metrics绕过旧分析器。
- **兼容回归**：3A-1原34,868译码控制/21语义、48个原top场景及8个原控制场景全部通过；默认metadata骨架与原3个坏RTL拒绝仍通过；原IF七项复用门121检查及独立457检查通过。IF序号耗尽测试的一条Fatal是预期拒绝，正常配置均0 error/warning。

控制覆盖：MEM源22次、WB源11次、x0源23次；12拍源阻塞、43拍EX持有、4拍MEM禁用、4拍WB背压、3次WB→ID源、2次跨epoch MEM源、21次MEM/WB不同owner同拍交接；3次人工unready恢复。这里的 `force result_ready=0` 只模拟ALU结果暂不可用，**不是执行了LOAD/M/CSR**，不构成load-use真实数据通路验收。

首次独立分析器曾错误要求变等待端点也严格提速，被1933=1933的实测结果拒绝；保存了原失败记录和100份良好CSV哈希。随后把规则改为两组不退化、fast组严格改善，原始数据未改。独立审查补充了rs1可用/rs2阻塞的镜像，第7项坏RTL确认该场景能抓到仅rs1保存门错误。

## 复跑与边界

工程根目录使用Python 3与ModelSim 10.6e：

```powershell
python -B tools/verify_cpu5_forward.py
```

该命令串行运行原ALU参考、新前递top/控制、独立分析器、IF复用及默认骨架；结果在 `build/cpu5_s3_verification/verification.json`。7个新增坏RTL的原始实跑记录冻结于[长期证据](evidence/cpu5_forward_20261021/README.md)，各自含坏源/DO/trace/日志。实测源字节SHA与规范LF SHA同时保存，完整基线与实测源归档在本机 `build/verification/cpu5_forward_20261021/`。

原1111份已有文件中仅修改本步3份：`rtl/cpu5_alu_pipeline.v`、`rtl/cpu5_top.v`、`tb/cpu5_alu_top_tb.v`；后者仅增加前递/输出目录参数，默认仍跑旧模式。其余1108份逐字节保护，包括原三级产品、用户未提交工作、正式固件/位流/P&R报告。

尚未接入分支、LOAD/STORE、D/M owner、CSR、Trap/IRQ、BP架构提交及十类周期分类；完整3A-2、A01–A16、CPU5 P&R/资源、50MHz板测和CoreMark均未验收。新前递逻辑没有改变已验收三级的成绩。下一步接入分支控制流和RAM访问，分别补齐branch-use与真实load-use/写后读/事务归属门。
