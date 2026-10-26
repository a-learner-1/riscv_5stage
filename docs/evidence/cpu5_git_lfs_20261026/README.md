# CPU5 LFS 与历史基线兼容验收（2026-10-26）

验证代码提交：`6e9da66d3e217aa78b8a7aaf3f5662b5171d4477`。

19 对迁移提交的源码和清单保持相同 Git blob；11 个 ZIP（979,974,279 字节）的内容同时匹配原 Git blob 与 LFS SHA-256。上传副本已展开 ZIP，并安装 19 个本地兼容引用。

独立测试仓库由已发布历史导出，无 alternates，19 个原提交对象均不存在；76 次旧编号源码目录读取通过，现有 S16 归档校验函数检查 S15/S14 共 27,572 个条目。11 项损坏、未展开与引用冲突检查均拒绝；重复安装创建 0 个引用。独立仓库通过 Git fsck。

原开发目录 4,744 个受保护文件及 HEAD/status 的复核结果见 `original_checkout_protection.json`。代码、迁移证明和说明的原始/LF 哈希及提交 blob 见 `source_identity.json`。

此次没有重跑 CPU 仿真、正式 CoreMark 性能测试、综合或上板。初始化方式和引用的语义见 `../../cpu5_git_lfs_compat_20261026.md`。`verification.json` 中的本地测试目录仅记录运行现场，可用仓库内测试脚本重新生成。
