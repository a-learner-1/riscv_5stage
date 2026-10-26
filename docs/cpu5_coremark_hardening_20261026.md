# CPU5 CoreMark S18：独立计时、终止排空与证据加固

本阶段在产品 RTL 保持不变的前提下，重新运行 AXI／D0 数据后端 × 双 Cache 关闭／开启的四种真实 RV32IM CoreMark 配置。仍为 performance 种子、1 次迭代、功能 smoke 模式；不据此发布正式 CoreMark 成绩。

## 本次解决的问题

仿真原始数据按唯一 run_id 分目录保存，记录编译前后源码 SHA、私有源码快照、固件 ELF／ROM／RAM／map／反汇编、编译命令、工具链身份、ModelSim 日志及精简波形。CSV 在验证解压后字节一致的前提下压缩，避免重复使用全局 cases 目录中的旧结果。运行器只输出 `SIMULATED`，完整审计和负面证据通过后才允许交付。

终止标记按同一条指令的 seq／PC／指令字绑定请求、响应、完成、退休和写回。测试专用外壳在 TOHOST 接受后停止提交新的取指请求，保留已经呈现的背压请求并排空已接受的请求；所有流水级、数据／M owner 和写回队列排空后，才由共享复位取消最后一个从未被接受的取指呈现。三个外壳由原 RTL 机械变换生成，`fetch_enable=1` 时使用原有请求行为，未修改产品 RTL。

计时器审计记录真实 high／low／high 端点执行读数，并用独立逐拍 mtime 模型校对。Stats 的 START／STOP 读边沿同时记录 D owner、M owner、累计周期事件和实时 Cache／BTB 计数。宿主程序重算计时区间、十类周期分区及所有快照读回值，不以摘要或串口输出互相一致代替原始记录。

独立 RV32IM 解释器按退休轨迹回放程序，核对 PC、ROM 指令字、寄存器结果、访存描述和每条对应的物理写回包；从初始 RAM 镜像与实际 native 写事务重建最终 4096 个 RAM 字。串口 MMIO 写入、端点文件和真实 UART 引脚解码文件相互核对。Windows ModelSim 文本输出的 LF→CRLF 只允许精确的逐字符展开，文件原始哈希仍保留。

## 四配置实测窗口

固定参数：50 MHz 仿真时钟、5 Mbaud 加速仿真串口、I/D Cache 各 4 组 × 2 路 × 16 字节（各 128 字节）、16 项 BTB、EX 分支解析、前递开启。Cache 列的“开”为 I/D 同时开启。

| 后端 | Cache | 窗口周期 | 窗口退休指令 | 原始 mtime ticks | 边界开销 |
| --- | --- | ---: | ---: | ---: | ---: |
| AXI | 关 | 661,985 | 289,747 | 661,901 | 84 |
| AXI | 开 | 1,235,984 | 289,747 | 1,235,820 | 164 |
| D0 | 关 | 386,441 | 289,747 | 386,389 | 52 |
| D0 | 开 | 845,286 | 289,747 | 845,166 | 120 |

四配置整个程序合计 5,979,087 个周期、2,409,425 条退休指令，退休与物理写回逐条相符；最终 RAM 重建一致。算法窗口合计 3,129,696 个周期。CRC 固定为 seed `e9f5`、list `e714`、matrix `1fd7`、state `8e3a`。每配置实际读取 96 次 Stats、6 次 mtime。不同配置之间的周期快慢、work_other 波动及预测器计数差异仅记录为观察，不能作为功能通过条件。

## 故意损坏测试

43 项证据篡改全部拒绝：13 项检查范围／文件身份／编译流程／固件收据，30 项直接检查原始语义。语义测试明确绕过容器哈希，必须触发指定的语义断言；仅仅哈希不匹配不计作语义拒绝。包括同时伪造串口、摘要、快照及 CPI 的共同偏移，再由逐拍事件账本识破。

另有 23 个独立解释器算术／访存／分支向量及 18 个错误 M 扩展结果拒绝检查。四个短真实 CPU 终止排空场景与独立 timer 夹具通过；timer 夹具覆盖 12 次执行／响应、23 个响应保持边沿、两次低字进位、一次 64 位回绕及 high／low／high 重试。

固件侧完成 20 个头文件／ABI 预处理场景，其中 15 个应拒绝场景均拒绝；GCC 实际 include 依赖闭包为 9 项。8 个后端身份用例执行生产版 portable_init C：4 个正确配对接受，4 个错误配对拒绝，退回旧的单向检查方式的 C 变体也被拒绝。这 8 项为 Windows 原生 C 夹具，不宣称为 RV32 错固件上硬件的系统试验。

## 复跑与封存

先按 [LFS 历史兼容说明](cpu5_git_lfs_compat_20261026.md) 初始化仓库。工具路径可通过 `--cross`、`--vsim` 调整，大型运行目录可通过 `--storage` 指定；默认通过 ASCII 路径的 junction 将运行产物保存在 D 盘。

```bash
python tools/run_cpu5_coremark.py
python tools/test_cpu5_coremark_probes.py
python tools/check_cpu5_coremark_firmware.py
python tools/verify_cpu5_coremark.py --source-commit <已提交的完整源码SHA>
python tools/freeze_cpu5_coremark.py
```

仿真与辅助夹具记录源码前后身份；后续修改审计器可单独重审同一次仿真的原始记录。封存要求四个真实 CoreMark 配置、完整负面证据及每个阶段的实测源码与指定提交的 LF blob 相符，不能用 Git index 冒充已提交源码。`--compile-only`、少于四配置或跳过负面测试的结果不能封存为完整通过。

新证据目录为 `docs/evidence/cpu5_coremark_s18_20261026/`，旧 S17 归档保持原样。`manifest.json` 给出源码提交、归档哈希与条目数；解压 `raw_evidence.zip` 到对应提交的干净工作区即可重审，无需旧开发目录或重新运行仿真。`python tools/freeze_cpu5_coremark.py --verify-only` 逐项校验已封存内容。

## 边界与下一阶段

本轮完成仿真和证据加固。尚未完成 CPU5 综合／布局布线／STA、资源与 Fmax 统计、CPU5 位流、上板测试或不少于 10 秒的正式 CoreMark 测量。旧三级 CPU 的板测成绩不作为五级 CPU 的成绩。后续先建立独立 CPU5 板级构建与时序验证入口，再确定上板配置并进行真实串口功能和性能测量。
