# CPU5 3A-1 冻结证据

基线46cabef，2026-10-21。仅21种整数ALU、GPR、保守RAW、MEM退休；完整CPU5 A01–A16未验收。

- `verification/verification.json`：最终三份ModelSim正例与独立CSV分析，所有实际输入SHA。
- `alu/`：550条程序、七组黄金字段、48场景CSV/metrics、第二套机器码解释器审计、3项坏CSV拒绝、压缩波形。
- `decode/`：34,868译码检查与21组语义正例；`independent_decode_verification.json`与`decode_mutants/`保留4个真实坏RTL拒绝。
- `control/`：主集成8场景；`independent_control/`为独立同源实跑与130行账本审计；`control_mutants/`含4个真实控制坏RTL及拒绝日志。
- `scaffold_compat/`：默认metadata骨架兼容，含原3个坏RTL拒绝。其JSON中的ISA NOT IMPLEMENTED特指默认SKELETON_ONLY=1。
- `initial_top_failure/`：最初TB隐藏ROM数组依赖导致PC0为X的失败日志和原TB。控制层最初正常$finish被脚本误判的日志也保留在独立目录。
- `source_identity.json`：实测字节SHA及规范LF SHA；`manifest.json`冻结本证据目录每份文件，排除manifest自身。

1193次退休=1193个WB包，其中1123物理GPR写、70个x0禁写包。人工控制账本17退休=16写+1个reset丢弃待WB包。
负向测试的Fatal/exit1是预期拒绝；最终正常进程均exit0、0 errors/warnings。无新P&R、资源、板测或CoreMark结论。
波形用gzip压缩；完整基线/实测源归档及保护快照在本机 `build/verification/cpu5_alu_20261021/`。
