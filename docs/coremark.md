# CoreMark 测评准备（2026-10-03）

本阶段保持自研 RV32I 的 IF → EX → WB，以及原来的 `main`。官方 `benchmarks/coremark/` 算法与框架文件保持原样，计时和输出改动仅在移植层。正式成绩尚未测得；本轮不下载 FPGA、不烧写 Flash、不使用远程平台。

## 配置和构建

在实际英文路径工程目录执行：

```powershell
Set-Location -LiteralPath 'D:/FPGA/riscv_3stage'
cmd.exe /c build_coremark.bat --profile smoke
cmd.exe /c build_coremark.bat --profile smoke-validation
cmd.exe /c build_coremark.bat --profile formal-short
```

| profile | 种子 | 默认时钟 / UART | 迭代 | 判定 |
| --- | --- | --- | --- | --- |
| smoke | `0,0,0x66` | 100 MHz / 5 Mbaud | 1 | CRC、类型与报告必须正确；豁免短时 |
| smoke-validation | `0x3415,0x3415,0x66` | 100 MHz / 5 Mbaud | 1 | 同上 |
| formal-short | 性能种子 | 100 MHz / 5 Mbaud | 1 | 刻意不足 10 秒，必须 FAIL；是负测 |
| performance | 性能种子 | 50 MHz / 115200 | 0（自动校准） | 正式模式，严格检查时长与校验 |
| validation | 校验种子 | 50 MHz / 115200 | 0（自动校准） | 同上 |

CLI 支持 `--iterations N --clock-hz HZ --uart-baud BAUD`、`--cross` 工具链前缀和 `--name` 独立输出名。正式 profile 使用非默认时钟或波特率时必须指定独立名称，不能覆盖板级默认镜像；不同 profile 的预留名称不可混用。迭代值 0 只供正式模式自动校准。时钟设置必须匹配实际硬件；填写频率不会改变硬件时钟。`--help` 查看完整选项。

每个 profile 有独立 `programs/coremark_<profile>.hex`、`_data.hex` 和 `_config.vh`（文件名中的连字符转下划线），以及 `build/coremark/<profile>/` 中的 ELF、MAP、反汇编、生成配置头和 `build_report.json`。smoke 还更新旧的 `coremark.hex` 与 `coremark_data.hex` 兼容名。报告记录真实编译器版本、全部选项、RV32I/ILP32 的 libgcc、输入及镜像哈希、存储占用和栈余量。生成头必须与本次镜像配套，不能直接套用别的 profile。

## 计时和输出

专用仿真和板级顶层显式启用 `ENABLE_TRAPS=1`、`ENABLE_TIMER_IRQ=1`，中断保持复位后的屏蔽状态。使用现有 `timer_read_time()` 的 HI → LO → HI 重试读取，保存完整 64 位起止值；mtime 每个 CPU 时钟加一。原框架 `start_time()` / `stop_time()` 只包围算法执行，初始化、CRC 检查和 UART 打印不计入算法时间。自动模式的预估轮次会重启计时，最终结果只用正式一轮。

`CORE_TICKS` 是 64 位，秒数用软件 double 计算；GCC 仍以 RV32I 构建，软件浮点和 64 位运算来自匹配的 libgcc，不需要硬件 F/M 扩展。移植层的 `ee_printf` 支持必要的小数与 64 位格式，并接管原框架截为 32 位的 `Total ticks` 行。UART 增加 `COREMARK key=value` 数据，包括完整 ticks、实际迭代数、秒数、迭代速度、CoreMark/MHz、种子、CRC、时钟和编译信息。

换算关系：`seconds = raw_ticks / cpu_hz`；`iterations_per_second = iterations * cpu_hz / raw_ticks`；`coremark_per_mhz = iterations * 1000000 / raw_ticks`。保存完整整数 ticks 后可以在主机用精确有理数复核，小数打印只是显示值。

总数据配置为 **2000 字节**。框架三算法分配后打印 `CoreMark Size: 666` 是每算法大小，不能把它误认为总配置只有 666 字节。性能 seedcrc=`e9f5`，list/matrix/state=`e714/1fd7/8e3a`；校验 seedcrc=`18f2`，CRC=`e3c1/0747/8d84`。最终 CRC 随迭代数变化，应保存而不机械套用单次值。

任何模式的 CRC、类型、未知种子、缺失报告、零时间和非法数字输出都会失败。正式模式还要求原框架确认校验通过，且完整 ticks 不小于 `10 * cpu_hz`。单个 `FORMAL PASS` 只说明该次固件检查通过；正式报告还需要同配置的性能及校验两次运行、真实硬件时钟依据和完整 UART 记录。

官方依据：[EEMBC CoreMark Run/Reporting rules](https://github.com/eembc/coremark#run-rules)。要求至少 10 秒、2000 字节总数据、性能和校验种子均验证通过，以及统一编译选项。当前短程仿真与工具估算频率不构成正式成绩。

## 本轮新增验证

```powershell
cmd.exe /c build_coremark.bat --profile performance
python tools/build_coremark_port_tests.py
```

构建上面三个短程 profile 和 performance 默认镜像（用于有界板级启动）后，在 ModelSim Transcript 执行：

```tcl
cd D:/FPGA/riscv_3stage
do run_coremark_prepare.do
```

只运行新增的真实 CoreMark 性能/校验种子短程、正式短时拒绝、专用板顶层启动/复位，以及 50/100 MHz 和 smoke/formal 四种移植层 fixture。各组独立保存 WLF；运行结束必须有 `test_pass=1`。fixture 复用真实的 `timer_read_time()`，仅将 MMIO 读取替换为受控序列，覆盖低字回卷重试、超过 32 位的耗时、小数秒、格式输出及失败路径。**fixture 的模拟 ticks 不用于性能计分**。

已验证且相关代码未变化的旧 CPU、timer IRQ、AXI、外设仿真不重复运行；也不运行完整 10 秒 HDL 测评。看已有波形可直接 `vsim -view build/coremark_smoke.wlf`（以脚本保存的文件名为准）。

## 板级后续入口

板子可用后先构建同一硬件配置的正式镜像：

```powershell
cmd.exe /c build_coremark.bat --profile performance
cmd.exe /c build_coremark.bat --profile validation
```

新增 `coremark_board_top` 使用 MES50HP 的 50 MHz、115200、原引脚与 KEY1 复位，内部 32 KiB ROM / 16 KiB RAM，无 Cache，存储时钟与核心 1:1。默认加载 performance 镜像；通过专用 PDS variant 选择匹配的正式 profile。本轮仅验证接入与构建配置，不执行 PDS，未生成对应新位流，未实物验收。不要使用旧 trap_board 位流宣称完成本轮 CoreMark。

正式自动校准和运行需要时间；板上应等完整结果。报告同时保存源码与固件哈希、编译器/完整参数、实际时钟与存储配置、性能及校验 UART 日志；再据此建立 Cache、BTB 等后续改动的基线。

未来的 PDS 入口（本轮未执行）：

```powershell
cmd.exe /c build_pds_board.bat --variant coremark_board --firmware coremark_performance --stage bitstream
cmd.exe /c build_pds_board.bat --variant coremark_board --firmware coremark_validation --stage bitstream
```

两次位流分属 `build/pds_coremark_performance/` 和 `build/pds_coremark_validation/`。构建入口核对正式 profile、50 MHz/115200 和镜像/配置的 SHA-256，拒绝使用错误或过期固件。固件正式构建报告需要保留，或从源码重新生成。

## 已完成的本轮验证

| 项目 | 结果 | 仿真结束 |
| --- | --- | --- |
| smoke 性能种子 | CRC、64 位计时区间、RAM/UART 一致 | 15,859,040 ns |
| smoke-validation 校验种子 | 同上 | 16,696,990 ns |
| formal-short | CRC 正确、因不足 10 秒而拒绝（负测通过） | 15,786,410 ns |
| 专用板顶层启动/KEY1 复位 | 50 MHz/115200、timer 运行、IRQ 屏蔽 | 2,580 ns |
| RV32 移植层四种 fixture | 52 项边界通过，模拟时钟不计分 | 17,495,656 ns |

已通过各组最终 0 错误、0 警告，构建 CLI 7 项、PDS 固件匹配保护 5 项通过。五种正式/短程 profile 均构建通过，代码 28,092–28,176 字节、数据 3,860–3,944 字节，栈余量 10,344–10,420 字节，链接代码逐字检查为 RV32I。小数秒、迭代速度、CoreMark/MHz 的 UART 输出还与主机精确换算核对到 9 位小数。

性能种子单次算法区间 951,040 ticks，校验种子为 1,017,429 ticks；这些仅是当前配置的短程功能观察，不能作为正式成绩。初始化和 UART 输出后的整程序 cycles 更大，二者不可混用。

启动检查首次发现测试断言错误：原 `cycle_count` 等到首条有效指令才计数，`mtime` 则在复位释放后立即计数。修正为独立统计时钟拍数与固定启动偏移，单独重验启动组通过；没有改 CPU，也没有重复前三已通过算法组。原尝试日志与修复日志均保留。

证据位于 `build/coremark_validation_summary.json`、三个独立算法验证日志、`coremark_board_startup_validation.log`、`coremark_port_math_validation.log` 及配套 WLF；`build/coremark_prepare_validation.log` 保留了首次完整运行与已解决的断言失败。
