# 统一仿真回归入口（代码准备，验证待完成）

**更新：2026-10-11。** 本步骤新增双击菜单、分组回归清单、前置镜像检查和结果汇总，复用现有 ModelSim 自检。本轮按“暂时不验证”的安排只准备源代码，未运行入口、参数检查、编译、仿真、PDS 或上板，没有新增 PASS 或性能成绩。

## 双击使用

在 `D:\FPGA\riscv_3stage` 双击 `run_regression.bat`，进入中文菜单。选择对应测试组后才启动仿真；查看清单、生成计划或退出不启动 ModelSim。菜单结束后保留窗口，方便阅读提示。

输入测试组编号，可用逗号选择多组；`A` 运行所有组，`P` 只保存计划，`L` 查看入口清单，`0` 或直接回车退出。

Python 3 和 ModelSim 须已安装。入口使用 ModelSim 的命令行模式，逐项运行已有 `.do`，结果写入独立日志。它用于功能仿真；实物下载、PDS 资源和时序验收仍使用各自操作说明。

## 测试分组

| 分组 | 范围 | 镜像前置条件 |
| --- | --- | --- |
| `baseline` | 原 CPU、分支、访存、外设、握手、SoC 与同步异常兼容回归 | 各旧平台对应 HEX／RAM 初始化文件 |
| `cache` | 指令 Cache、数据 Cache、统计接口与配套固件仿真 | I/D Cache 固件、符号头与有效构建报告 |
| `btb` | 预测器、取指预测元数据与 CPU 定向场景 | 既有空白测试镜像 |
| `irq` | 定时器、外部／软件中断定向场景及演示外设 | 定时器 C 镜像及定向场景使用的空白镜像 |
| `coremark` | 原短程／移植层测试与 AXI 三配置各两种短程测试 | 各短程镜像、配置头、数学测试镜像及构建报告 |
| `board` | 新三源中断固件的 UART、LED、KEY1 模拟板级自检 | `machine_irq_board` 硬件指令、仿真 RAM、符号头与构建报告 |
| `axi-write-profile` | CPU STORE 分段延迟与既有 AXI 错误／复位恢复七平台 | 既有空白、`c_demo`、`trap_demo` 镜像；无需新固件 |

`all` 选择清单中所有分组，包括 `board`。可只选择与修改相关的组；清单不覆盖所有参数组合、综合网表、物理时序或实物验收。未选的场景明确保留 `NOT_RUN`。

## 命令行使用

在 Git Bash 中查看清单：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c run_regression.bat --list
```

仅生成计划，记录所选场景的前置文件和缺失项：

```bash
cmd.exe //c run_regression.bat --group all --plan
```

计划模式不调用 ModelSim、固件检查子进程或 Git；所有测试保持 `NOT_RUN`，计划不能作为通过记录。

以后恢复验证时，可选择单组或多组：

```bash
cmd.exe //c run_regression.bat --group btb
cmd.exe //c run_regression.bat --group irq,board
cmd.exe //c run_regression.bat --group baseline --group cache
```

`--group all` 会实际运行清单中的所有组，可能需要较长时间。已经通过且相关源码未变的测试可继续使用原日志，不必仅为查看波形重复执行。

## ModelSim 路径

入口支持从 `PATH` 查找 `vsim`，或通过 `--vsim`／`MODELSIM_VSIM` 指定实际可执行文件路径。未找到工具时显示 `BLOCKED` 及配置提示。

在 Windows CMD 中可按自己的安装位置设置，例如将下方路径替换为真实 `vsim.exe`：

```bat
set "MODELSIM_VSIM=C:\你的安装目录\win64\vsim.exe"
run_regression.bat --group btb
```

工程继续使用英文路径。运行前应关闭正在修改同一工程的其它仿真任务，避免共用旧脚本的工作库、`modelsim.ini` 或波形文件。每个测试场景使用单独的 ModelSim 进程，但旧脚本中的工作库和 WLF 路径仍保留原定义。

## 前置检查与结果

运行模式先检查所需文件，再调用只读固件一致性检查。缺少或过期的镜像／构建报告显示 `BLOCKED`，并给出对应的固件构建命令；入口不会自动编译 GCC 固件。Cache、AXI CoreMark 和三源中断固件继续使用各自已有的来源／镜像一致性规则。

旧 CoreMark 数学测试报告只记录三份源码哈希，没有镜像或 ELF 哈希。新增检查会将现有 HEX 与保留的二进制逐字节对照，并核对报告和符号头；这仍受旧报告格式限制，不能据此声称证明了全部构建输入的来源。

| 状态 | 含义 |
| --- | --- |
| `PASS` | 该场景进程正常退出，本轮独有完成标记和所有必需成功证据齐全，且无仿真器 Error／Fatal，输入未在运行中变化 |
| `FAIL` | 已启动的场景出现工具或仿真错误、超时、缺少成功证据，或运行中输入发生变化 |
| `BLOCKED` | 前置文件、固件匹配或工具路径条件未满足，没有启动该场景仿真 |
| `NOT_RUN` | 未选、仅列计划，或中断后尚未运行的场景 |

命令退出码：`0` 表示查看清单、生成计划、退出菜单或所选测试全部通过；`1` 表示测试失败；`2` 表示前置条件阻塞或入口异常；`130` 表示用户中断。计划模式返回 `0` 仍然是未运行，验收应读取报告中的状态和选择范围。

原 `formal_short` 故意运行不足正式测量时长，其固件输出 `COREMARK RESULT: FORMAL FAIL` 是待检查的负例；测试平台正确识别拒绝正式成绩后仍可通过。因此入口不搜索裸 `FAIL` 字符串判定失败，必须依据对应场景的完整验收证据。短程测试、模拟板级串口输出以及统一回归 `PASS` 都不能作为新的 CoreMark 正式成绩或实物 PASS。

## 日志与复现

每次运行／计划使用独立目录 `build/regression/<run_id>/`，保存场景日志、前置检查日志、生成的 Tcl 包装入口及 JSON／中文 Markdown 汇总。报告记录选择范围、状态、原因、前置构建提示、工具路径和输入哈希；真实运行还尝试记录 Git 提交与工作区状态，未能读取时明确说明。

汇总文件为 `summary.json` 和 `summary.md`。`build/regression/latest.json` 只指向最近一次报告；打开时须确认运行编号、是否为计划、选择范围和状态，不能仅凭这个定位文件判断通过。

PASS 证据取自本轮独立进程及完成标记，不读取旧日志替代本次结果。报告不纳入 Git；本轮只提交入口源码和说明。默认不会改变既有 RTL、固件算法或 `.do` 的验收逻辑。

若要扩大回归范围，编辑 `tools/regression_suites.json`，为每项补齐脚本、依赖、前置检查、超时及精确成功标记，并核对测试平台中的真实完成路径。旧 affected 回归须保留所有子平台的成功证据，不能只凭总组数或进程返回 0 判为通过。

## 周期分类扩展（2026-10-16）

新增 `cycle-profile` 分组，运行无需 GCC 的六类周期分类定向测试；新增 `coremark-axi-profile` 分组，只运行 AXI 统计及六种真实 C 短程对照。后者须先执行 `build_coremark_compare.bat --profile smoke` 和 `build_coremark_compare.bat --profile smoke-validation`，生成 schema 3 匹配镜像。具体计数口径及本次结果见 [周期统计说明](cycle_profile.md)。

## AXI 写通路分析（2026-10-16）

新增 `axi-write-profile` 分组，包含 `run_axi_write_profile.do` 的逐事务／分段 CSV 以及既有 `axi-latency-directed` 恢复验证。运行方法、采样边沿与结果解释见 [写通路分析](axi_write_profile.md)。
