# CPU5 整数控制流冻结证据

2026-10-22，基线087fcc6。实现六种B、JAL/JALR；ID/EX真实解析切换、MEM退休BP授权。
仅整数ALU与控制流子集，真实LOAD-use/RAM、Trap/IRQ、M/CSR、完整A01–A16、STA与板测未验收。

- `verification/verification.json`：最终6个顶层进程exit0，实测源SHA及关键总账。
- `branch/`：367退休主程序与10fault、48case原始CSV/metrics、第二解释器；3064退休=3064WB、739redirect、1532真实BP训练、3152ID接受。
- `unit/`：77,070组合检查、22手写编码、5坏RTL；`control/`：ID/EX各15场景、32退休/WB、22写、16redirect、10坏RTL。
- `analyzer_selftest/`：6个独立坏CSV副本和拒绝原因；`branch/analyzer_selftest.json`记录333个良好输入前后哈希不变。全量48case报告在 `branch/analysis.json`，与自检报告分开。
- `reference_*`、`if_compat/`、`scaffold_compat/`：旧ALU/前递、IF复用及默认metadata模式的当前同源复跑，含各自预期拒绝。
- `source_identity.json`：实测字节及规范LF SHA；`manifest.json`冻结证据目录所有文件，排除自身。

ID重定向随IDtransfer、EX重定向抑制年轻同拍进入。外部flush暂停存活源一拍再试，已退休WB可继续排空。
错位/IF错误只停MEM，不是Trap入口；fault fixture仅核初始化/成功写过的物理GPR，不能用oracle零值声称regfile reset清零。
所有最终正常配置0 errors/warnings；坏RTL/IF耗尽的Fatal/exit1为预期拒绝。周期表属于定向程序，非CoreMark/时序/板测成绩。
完整基线、实测源和保护快照另在本机 `build/verification/cpu5_branch_20261022/`；WLF用gzip压缩。
