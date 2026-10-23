# CPU5 最小同步 Trap 冻结证据

2026-10-23，基线e58148e。固定TRAP_VECTOR、MEM故障裁决和诊断PC/cause/tval；没有软件CSR、MRET、IRQ、M、MMIO、Cache/AXI/SoC、STA或板测成绩。

- verification：最终同源总脚本，参考源逐SHA复用；新控制/端到端/独立分析/坏证据自测全通过。
- trap：13故障×ID/EX×BP×wait，104场景；1042退休/WB、104 Trap、336 D、1586 I账本闭合；包括held/stale IFerror和年轻ID跳转后老LOAD报错。
- control：54场景、54 Trap、94退休/WB、26 D；MEM暂停、旧WB写/持有、error completion ack、handler与killed LOAD drain进展。
- control_mutants：15个实际坏RTL及指定断言；parameters：2项非法参数guard拒绝；drivers记录独立源SHA和复现脚本。
- analyzer_selftest：13个真实损坏CSV/RAM/GPR副本和拒绝原因，良好输入SHA前后不变。
- reference_*_verification：当前同源RAM/分支/前递/ALU/IF/骨架兼容汇总与运行日志；历史完整证据仍在各前阶段目录。
- source_identity：实测字节与规范LF SHA；manifest冻结目录（排除自身）；protected_files_check只授权6个已有CPU5源/TB更新。

正例0 error/warning，坏RTL/guard/旧IF耗尽的Fatal/exit1为预期拒绝。handler只初始化7个可定义GPR（含x0），另25个保持X；JAL自环正常退休，停机由测试端I-READY关闭与流水排空实现。failed STORE端点的“不写RAM”是fixture选择，不是CPU回滚承诺。
完整基线、实测源和交付脚本在本机build/verification/cpu5_trap_20261023；波形gzip压缩。
