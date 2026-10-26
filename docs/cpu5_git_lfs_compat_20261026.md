# CPU5：LFS 迁移后的历史基线兼容（2026-10-26）

GitHub 的普通 Git 推送拒绝了四个超过 100 MiB 的原始证据 ZIP。此次已将尚未推送的 19 个提交中的 11 个 `raw_evidence.zip` 转入 LFS，GitHub 的 `main` 从 `1b7cb12` 更新至 `4299b9e`。旧开发目录仍保留原历史与未提交改动。

## 下载后运行一次

在 Git Bash 中执行；`python` 需为 Python 3.9 或以上：

```bash
git clone https://github.com/a-learner-1/riscv_3stage.git
cd riscv_3stage
git lfs install --local
git lfs pull
python tools/setup_cpu5_git_baselines.py --install --report build/cpu5_git_baseline_setup.json
```

已经下载仓库的用户，从 `git lfs install --local` 开始执行即可。该工具先完整校验迁移证明与证据归档，再安装 19 个本地 Git replacement refs。再次执行不会重复创建；遇到冲突引用会停止，不覆盖已有引用。

## 为什么需要这一步

旧验收工具及冻结证据引用原提交编号。例如，S16 的旧编号是 `6a39363a70440be7b2a3a064ddedf1b6196cc904`，迁移后对应 `9ca3508e109dd946017942590458adfeba296de2`。直接修改工具中的 `BASE` 会与证据清单中的历史编号产生冲突。

兼容工具采用 Git 自带的 [replacement refs](https://git-scm.com/docs/git-replace)。例如，安装后 `git show 6a39363a70440be7b2a3a064ddedf1b6196cc904:rtl/cpu5_top.v` 读取迁移后提交中的同一份源码。它不会重建原提交对象；`git cat-file -p <旧编号>` 此时返回替代提交的内容，不能声称其原始对象哈希仍是旧编号。LFS 迁移后的归档 blob 是指针，实际 ZIP 由工作区或 LFS 对象库提供。

这些引用仅存于本地 `.git/refs/replace/`，普通 clone/pull 不会自动安装，普通 `git push origin main` 不会上传它们。因此每个新 clone 都需执行上述初始化。取证时可用 `git --no-replace-objects ...` 显式禁用引用；正常运行旧验收工具时请勿设置 `GIT_NO_REPLACE_OBJECTS` 或自定义 `GIT_REPLACE_REF_BASE`。

## 如何证明映射正确

`docs/cpu5_lfs_migration_20261026.json` 保存原提交的原始字节以及发生变化的原目录树对象，体积约 225 KB，不包含大 ZIP。工具通过 Git 对象哈希验证以下关系：

1. 19 对提交的父提交链从同一个已发布提交 `1b7cb12` 出发，旧、新链分别止于固定的 `a8bcedf`、`4299b9e`；作者、时间和提交信息一致。
2. 递归比较原目录树与新目录树，允许的变化仅为根目录新增 LFS 属性规则和 11 个归档变为 LFS 指针；其余 blob ID 与文件模式相同。源码、固件、测试和证据清单由此保持逐字节一致。
3. 对实际 LFS 数据计算 SHA-256、字节数和带 Git blob 头的 SHA-1，分别匹配 LFS 指针与迁移前的 Git blob ID。
4. 安装前要求工作区中的 ZIP 已展开，避免用指针文本运行 ZIP 审计。

证明独立于原开发目录和未被清理的旧 Git 对象。测试工具会导出仅含已发布历史的 pack，构建没有 alternates、没有 19 个旧提交的独立仓库，安装引用后读取各阶段历史源码，并调用现有 S16 归档校验函数检查 S15/S14 冻结归档。损坏证明、数据和冲突引用均须被拒绝。

```bash
python tools/test_cpu5_git_baselines.py --output build/cpu5_git_baseline_test
```

测试输出目录必须尚不存在。此测试需要复制约 980 MB 归档；结果保存在该目录的 `verification.json`。

## 当前工作目录与验证范围

后续与 GitHub 同步的开发入口是 `D:\FPGA\riscv_3stage_github_lfs`。旧目录 `D:\FPGA\riscv_3stage` 保留三份原有已修改文件和未跟踪文件；S18 的隔离工作区仍借用其 Git 对象库，暂时保留旧目录。

本次验证的是历史迁移的内容完整性与基线读取兼容性。旧冻结报告和归档保持原样。测试没有重跑各阶段 CPU 功能仿真，也没有进行 CoreMark 正式成绩测试、综合、布局布线或上板测试。某个早期阶段的验收器若要求“当前源码完全等于当时源码”，仍可能因之后的正常功能升级而拒绝；兼容引用不豁免这些检查。

CoreMark S18 的计时、终止排空、独立计数审计加固仍在隔离工作区中，尚未作为已验收成果发布。
