# CPU5 普通 RAM 冻结证据

2026-10-22，基线 b5f7a70。仅ALU/整数控制流/普通RAM原生D接口，错误停MEM；未接MMIO、CSR、M、Trap/IRQ、Cache/AXI/SoC。没有CPU5资源/STA/板测成绩。

- `verification/verification.json`：7项最终正例进程、源SHA、16 C场景23520退休/WB、5744请求/响应。
- `ram/`：双种子真实C的ELF、反汇编、两套独立oracle、向量和16场景accept/retire/WB/BP/D账本、完整RAM终态。
- `control/`：ID/EX各25场景；共118退休/WB、46请求/响应，包含STORE三态flush锁、LOAD kill排空、old fault和I/D分类。
- `unit/`、`owner/`：18804组合检查，81 owner检查；owner reset场景解释了19 issue/18 request/17 response。
- `ram_unit_mutants/`、`owner/mutations/`、`core_mutants/`：6+9+10个实际坏RTL；全部先成功编译再由指定断言拒绝。4项非法参数见`ram_unit_parameters/`。
- `analyzer_selftest/`：10个实际坏证据副本及拒绝原因；162个良好输入SHA前后不变。
- `reference_*_verification/`：当前同源旧ALU/前递/分支/IF/骨架兼容复跑汇总与日志。详细历史证据保留于各前阶段目录。
- `source_identity.json`：实测字节和规范LF SHA；`manifest.json`冻结证据，排除自身；保护检查只允许5个CPU5旧源/TB更新。

issue_fire在首次呈现边沿分配owner；req_fire只表示端口接受。epoch不杀D owner，killed LOAD继续drain，STORE不可撤销。STORE error无回滚承诺，本阶段需reset恢复。
正常配置0 error/warning；坏RTL/非法参数及旧IF耗尽的Fatal/exit1为预期拒绝。drivers脚本记录此次隔离副本布局；工程常规复跑用tools/verify_cpu5_ram.py。
完整基线、实测源、交付脚本和保护快照另存本机build/verification/cpu5_ram_20261022。波形、ELF与二进制使用gzip。
