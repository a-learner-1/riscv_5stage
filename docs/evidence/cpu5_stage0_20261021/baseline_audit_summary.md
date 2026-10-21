# CPU5 阶段 0：三级 RV32IM 基线只读冻结审计

审计状态：**PASS**。此结论只覆盖既有来源、归档与板测数据身份，不代表重跑仿真、PDS 或 CPU5 验证。

检查：845 PASS / 0 FAIL。未修改主工程、索引、Git refs 或原产物。

## Git 角色

| 角色 | 完整 commit |
|---|---|
| m_work_start | `75c43aabb0581ec303664e0f51b48c387e1962db` |
| accepted_rv32im_source | `347982c30c88095d4a6406bd26c535b7b9f468b5` |
| board_evidence | `ab8e3f61664792e0379f08294adf55635c4f8b1e` |
| current_head | `1b7cb1251f5ff589ab1a6be8537b3362cc3f3a73` |

拟冻结 tag：`cpu3-rv32im-board-20261021` → `347982c30c88095d4a6406bd26c535b7b9f468b5`。**本审计未创建 tag**。板测证据另绑定其证据 commit。

## 保护现场

事前记录 3 个用户已跟踪修改及 182 个 Git 可见非 ignored 未跟踪文件，逐文件大小/SHA-256 见 JSON。审计末尾再次核对，未改变。

Ignored build 文件不混入用户未跟踪源码清单；仅核验发布清单显式引用的原产物，不复制大波形。

## 交付身份

两份正式 SBIT 各 2,101,696 字节；发布 manifest、delivery identity、原始 PDS manifest、route/RTR、实现产物与原始 firmware report 均按原 SHA 核对。

当前正式 ROM/RAM/config 三件套与位流输入逐字节一致。原始源码、Git blob、当前工作区的 raw SHA 分别保留，CRLF/LF 仅以归一化方式证明等价，**不宣称 raw 字节一致**。原 ELF 与重建 ELF 的已分配节和 PT_LOAD 内容/地址一致；非加载 .strtab 差异单独记录。

只读运行两份正式固件 contract 检查；没有重建固件。

## 正式板测证据

docs/evidence/rv32m_board_20261021 的全文件清单、证据 commit、pair→single→raw/normalized UART 哈希闭合。两组 metadata、flags、CRC、时长、六分类与 Cache 账本重新核算；performance 独立计分，不平均 validation。

performance：117.958048697 CoreMark / 2.359160974 CoreMark/MHz；2000 次，16.955180440 秒。

validation：117.763402970 次/秒，16.983204880 秒；I-cache refill 比 4×miss 多 3 字，保留为跨窗口边界差。两次 work_other−retired 均为 56,376,000，不能直接认定为纯 MUL 等待。

用户自行下载；UART 文本不能自证实际下载 SBIT SHA。发布 manifest 中硬件/正式成绩未运行字段保留为构建时快照，后续配对板测证据单独提供。

## NOT RUN

- Fresh ModelSim/lint/regression
- Fresh PDS/synthesis/place-route/STA
- Hardware download/UART access
- CPU5 development
- Freeze tag creation

完整路径、字节哈希、Git fuller 输出、差异及检查明细见 [baseline_freeze.json](baseline_freeze.json)，复核脚本见 [audit_baseline.py](audit_baseline.py)。
