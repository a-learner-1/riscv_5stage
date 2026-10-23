# CPU5 最小机器 CSR / MRET 冻结证据

2026-10-23，基线 `5be17af25087ab82eb85d913b4e37193b83db164`。

- `verification.json`：最终完整总验证，嵌套控制、真实IF/独立解释器与坏证据测试、RTL变异/参数guard结果，以及旧CPU5兼容链记录位置。
- `source_identity.json`：本次全部实测依赖的原始字节SHA与规范LF SHA。提交/跨CRLF工作区校验使用LF口径，不能直接比较原始字节SHA后宣称源改变。
- `raw_evidence.zip`：原始CSV、向量、正常/预期拒绝日志、波形、真实坏源和 `tested_sources/`。兼容链也在ZIP内；编译库不归档。
- `archive_entries.json`：ZIP每个entry的SHA256；`manifest.json`：本目录文件SHA256。

验证结果：86控制场景；16真实IF配置；14个RTL功能变异和4个独立非法参数拒绝；30项解释器自检、9份坏证据拒绝；旧CPU5全兼容链通过。正常配置零Error/Warning。RTL功能变异要求独立干净编译后由预先指定语义断言拒绝，不能用语法错/警告/库错误替代。

复跑：`python -B tools/verify_cpu5_csr.py`；冻结：`python -B tools/freeze_cpu5_csr.py`。只在当前源SHA与已有完整参考记录逐项相同时允许 `--reuse-reference`。先查看 [阶段报告](../../cpu5_csr_20261023.md) 和 [范围合同](../../cpu5_csr_contract_20261023.md)。IRQ/M/MMIO/SoC、完整A01–A16、STA、性能、板测均不在本轮完成范围。
