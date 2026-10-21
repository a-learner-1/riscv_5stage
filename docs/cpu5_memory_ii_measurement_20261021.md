# CPU5 阶段 0.5-B：三级访存接受间隔实测（2026-10-21）

实测通过。原 `cpu_top.v`、I/D Cache、D0 router 与同步 BRAM RTL 均未修改。
这是现有三级核的定向基线，不能称为 CPU5 实现验收或 CoreMark 新成绩。

| 边界及条件 | 请求→响应消费延迟 | 相邻接受间隔 II | 观测数 |
|---|---:|---:|---:|
| 独立 streaming Cache，hit LOAD→hit LOAD，无等待/背压 | 1 | 1 | 16 笔 hit；7 对 hit→hit |
| 三级 CPU→Cache，hit LOAD→hit LOAD，无后端等待 | 1 | 2 或 9 | 15 笔 hit；6 对 II=2、1 对 II=9 |
| 独立 Cache，hit LOAD→STORE，无等待 | STORE 为 2 | 1 | 3 对 |
| 三级 CPU，hit LOAD→STORE，无等待 | STORE 为 2 | 2 或 9 | 1 对 II=2、2 对 II=9 |
| 独立 Cache，真实 STORE→hit LOAD，无等待 | LOAD 为 1 | 3 | 3 对 |
| 三级 CPU，真实 STORE→hit LOAD，无等待 | LOAD 为 1 | 3 或 9 | 2 对 II=3、1 对 II=9 |
| D-Cache→D0 router→BRAM，无等待 | 1 | refill 连续读为 2 | 每 case 18 对 refill 内部读 |
| 同一后端，REQ_WAIT=2/RSP_WAIT=3，无消费背压 | 4 | refill 连续读为 7 | CPU 延迟 case 28 笔 backend |

II 的前缀严格表示**前一笔/当前笔的实际请求类别**，首笔没有 II。
原始 `SW-LW` 全桶包含非法 strobe STORE，其 II=1 不能用于描述真实 STORE 完成后的吞吐；应查询 `class_pair_interval.write->hit`。
CPU fixture 的四个不同 STORE 数据在访存序列前预置到 x5–x8，25 条有效访存指令连续排列，访存对之间没有插入数据准备 ADDI。

CPU hit→hit 的 II=9 对应 PC `0x2c→0x30`。`case2_ifetch.csv` 直接记录下一指令 I-Cache miss：请求 cycle 46、响应 cycle 55，D 请求在 cycle 56 接受；因此这个请求间隔包含前端供给缺口。其余类型的长 II 也保留在逐对 CSV，不假定它们都是数据端口固有开销。

四个并行 case 都使用 64 sets × 2 ways × 4 words 的原 D-Cache，并在三个边界记录接受/响应消费：Cache 入口、Cache→D0 router、router→BRAM。
case 0/1 是 streaming 主机，分别为零等待与 REQ_WAIT=2/RSP_WAIT=3，后者额外施加周期性三拍响应背压；各 30 请求/30 响应。
case 2/3 是原三级 CPU、原 I-Cache/ROM 和同一数据链，分别 26 请求/26 响应、36/35 条退休逐项比对，末尾非法地址/未对齐 LOAD 触发旧核 fault-stop，故障指令不退休。

覆盖两路、同组第三条 line 驱逐、跨 line/set、write-through/no-write-allocate、同地址 `SW [A]; LW [A]`、LW-LW/LW-SW/SW-LW、请求/响应背压、未对齐、非法 strobe、保留 size、越界错误。
两种 streaming case 各记录 25 次旧响应 A 与新请求 B 同拍，其中 18 对为地址和返回数据均不同的 LOAD；CPU 两 case 均为 0 次。
D0 router/BRAM 在四 case 中均无同拍旧响应/新请求接受，router 的 active 锁定断言每拍检查。

SV scoreboard 独立维护初始数据和写更新，检查响应 owner、数据、错误、重复/漏响应及持有稳定性。Python 另解码实际 ROM，独立比对所有 CPU 退休和 D 请求；独立 tag/LRU 模型验证 hit/miss/way；refill 每条 line 四拍和每个上层 owner 的后端请求数闭合。
分析器对错误读数据、错误 owner、漏响应、重复请求、错误 refill 地址、错误退休写回六种证据污染全部拒绝。
最终 ModelSim 10.6e 真实进程退出 0，编译/仿真 Errors=0、Warnings=0。

重跑：

```powershell
python -B tools/build_cpu5_memory_fixture.py
& 'D:\modeltech64_10.6e\win64\vsim.exe' -c -do run_cpu5_memory_ii.do -l build/cpu5_s05_memory/transcript.log
python -B tools/analyze_cpu5_memory_ii.py --negative-checks
```

机器证据位于 `build/cpu5_s05_memory/`：`case*_boundary*.csv`、`case*_metrics.csv`、`case*_retirement.csv`、`case*_ifetch.csv`、ROM/golden、`transactions.csv`、`request_pairs.csv`、`summary.json`、`analyzer_negative_checks.json`、`transcript.log` 与 `memory_ii.wlf`。

范围限制：非 RAM 错误使用原 `soc_data_mem` 的原生错误端点替身，只验证 router 错误归属，不替代 AXI 传输回归。请求读数据字段中未使用的 wdata 可以保留 X；有效 LOAD 响应、STORE 操作数和有效 GPR 写回必须由模型验证。延迟定义包含响应消费背压；当前没有 CPU5 RTL，CPU5 的 II=1、投机 LOAD 与 owner/kill/drain 均为 NOT IMPLEMENTED / NOT RUN。
