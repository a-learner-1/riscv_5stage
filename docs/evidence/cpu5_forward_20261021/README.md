# CPU5 整数前递冻结证据

2026-10-21，基线c77b7ec。仅3A-2整数ALU前递子集；真实LOAD-use、branch-use及完整A01–A16未验收。

- `verification/verification.json`：最终7个顶层进程均exit0，包含实测源SHA、A/B与控制账本。IF进程有一条专门序号耗尽测试的预期Fatal。
- `forward_top/`：50场景实际机器码/黄金字段/CSV/metrics/独立解释器与5坏CSV拒绝；2293退休=2293WB包，2153物理写、140个x0禁写。
- `control/`及`independent_control/`：主集成及独立13场景同源实跑。44退休=44WB消费、43写，46ID中2个被flush。人工unready不等于LOAD已实现。
- `control_mutants/`：7个真实RTL缺陷、相应运行断言、非零码和无整体成功标记；`control_mutation_driver.py`保留复现脚本。
- `reference_*/`：前递关闭的3A-1参考回归；`if_compat/`和`scaffold_compat/`保存原IF门、默认metadata模式及其预期坏样本。
- `source_identity.json`：实测原始字节SHA与规范LF SHA，供Git换行规范化核对；`manifest.json`冻结每份证据（排除自身）。

无取指等待同一550指令：1206→559；变取指等待：1933→1933，RAW消除被IF等待掩盖。不是CoreMark、板测或频率成绩。
首次analyzer曾错误要求两组都严格提速，原失败和100份未改良好CSV的SHA已保存；最终门要求两组不退化且fast组严格改善。
最终正常配置编译/仿真0 errors/warnings；独立负例的Fatal/exit1是预期拒绝。
波形为gzip压缩；完整基线与实测源及保护快照另在本机 `build/verification/cpu5_forward_20261021/`。
