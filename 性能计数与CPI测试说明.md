# 性能计数与 CPI 测试说明

## 本次新增

- `rtl/cpu_top.v`：增加 64 位 `cycle_count`、`instret_count` 和 `retire_valid`。
- `tb/performance_tb.v`：运行 `programs/c_demo.hex`，检查 `tohost`、退休指令数并计算 CPI。
- `run_performance.do`：ModelSim 性能测试脚本。
- `programs/c_demo.hex`：已经由当前 GCC 示例程序生成，可直接仿真。
- `build_program.bat`、`Makefile`：工具链前缀改为本机安装的 `riscv-none-elf-`。

## 计数规则

- 第一条受支持的有效指令进入 EX 后开始计周期。
- 每条未被冲刷、受当前 CPU 支持的指令到达退休点时，`instret_count` 加一。
- 分支、跳转和存储也计入退休指令。
- 复位气泡、分支冲刷气泡、越界取指和不支持的指令不计入。
- 测试在写 `tohost` 的存储指令退休后停止。

固定的 `c_demo.hex` 应执行 150 条退休指令。测试平台会检查这个精确值，从而发现错误计入气泡或错误路径指令的问题。

## 运行方法

ModelSim 10.6e 不适合直接在中文路径下建立工作库。请先把整个目录复制到：

```text
D:\FPGA\riscv_3stage
```

在 ModelSim Transcript 中运行：

```tcl
quit -sim
cd D:/FPGA/riscv_3stage
do run_performance.do
```

预期结果：

```text
PASS: performance counters and C program completed
PERF: tohost=1
PERF: cycles=174
PERF: retired instructions=150
PERF: CPI=1.160
```

若修改了 `software/main.c`，先在 CMD 中重新生成程序：

```bat
set "PATH=D:\Tools\xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64\xpack-riscv-none-elf-gcc-15.2.0-1\bin;%PATH%"
cd /d D:\FPGA\riscv_3stage
build_program.bat
```

修改 C 程序后，动态指令数量可能不再是 150，需要同步更新 `tb/performance_tb.v` 中的 `EXPECTED_INSTRET`，或为新程序建立独立的期望值。
