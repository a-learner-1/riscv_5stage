# CPU5 RV32M / M owner 冻结证据

基线 `3d2644e248347429610ca46a555c2ed361c6e9ae`，2026-10-23。

- `verification.json`：最终总验证，嵌套149个owner场景、44个控制场景、16组真实IF程序、独立参考/坏证据及所有变异/guard；关联当前同源全部CPU5兼容链。
- `source_identity.json`：实际测试依赖的原始字节与规范LF SHA。Git blob/跨CRLF工作区校验使用LF口径，原始ZIP和manifest使用字节口径。
- `raw_evidence.zip`：原始CSV、向量、日志、波形、真实坏RTL、兼容链与 `tested_sources/`。仅保留各套件最后完整run_id；编译库排除。
- `archive_entries.json`：ZIP逐entry SHA256；`manifest.json`：本目录逐文件SHA256。`.gitattributes` 保持冻结文件原始字节，检出时不转换换行。

20个真实RTL功能变异先独立0warning/error编译，再由预先指定语义断言拒绝；3个guard另列，不能用语法/编译/库失败替代。42项机器字自检、9份坏证据副本拒绝，良好输入不变。

复跑 `python -B tools/verify_cpu5_m.py`，冻结 `python -B tools/freeze_cpu5_m.py`。范围见 [合同](../../cpu5_m_contract_20261023.md)，结果和未实现项见 [阶段报告](../../cpu5_m_20261023.md)。IRQ/MMIO/系统集成、完整A01–A16、STA/性能/板测仍待后续。
