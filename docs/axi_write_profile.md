# AXI 写通路分段延迟分析

本项以 `b3b3c24` 的三级 CPU 和现有 AXI4-Lite 通路为基线，仅新增仿真观测。测试由真实 CPU 执行定向指令，经过可选 D-cache、数据桥、1×2 路由器及真实 AXI RAM。当前先取得分段数据，再决定 RTL 优化位置。

## 运行

在 Git Bash 中运行专项及现有错误／复位恢复测试：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c run_regression.bat --group axi-write-profile --vsim D:/modeltech64_10.6e/win64/vsim.exe
```

`axi-write-profile` 包含新增分析平台和既有 `axi-latency-directed` 七个平台。后者复查 RAM、路由器、桥、CPU、D-cache 故障及精确异常恢复。使用已有定向 HEX，不需要 GCC 构建。也可在 ModelSim Transcript 单独执行：

```tcl
do run_axi_write_profile.do
```

该 `.do` 只运行新增平台，以 `test_pass=1` 和独立完成标记确认完成。统一入口另外保存输入哈希和本轮日志。请在工程根目录执行，避免与同目录的其它 ModelSim 进程争用库和配置。

## 采样口径

周期编号是 testbench 的上升沿编号。握手事件根据上升沿到来前的 `VALID && READY` 记录；RAM 副作用根据该边沿真实存储器写使能记录。首次有效及退休则在同一边沿 NBA 更新后观察。所有相邻边沿相减得到周期数；同一边沿的两个事件之差允许为零。

| 事件 | 观察点 |
| --- | --- |
| STORE 发起 | CPU `mem_start_x` 且本指令为 STORE，保存 PC、地址、数据、字节掩码 |
| CPU 请求接受 | CPU→D-cache 请求握手；关闭 Cache 时是直连请求握手 |
| 桥请求接受 | Cache→桥请求握手；关闭 Cache 时与 CPU 请求接受重合 |
| 上游 AW、W | 桥→路由器两通道分别握手 |
| 下游 AW、W | 路由器→RAM 两通道分别握手 |
| RAM 真正写入 | RAM 内部存储器有效写使能及该拍地址／数据／掩码 |
| 首次 BVALID | RAM 和路由器响应在 NBA 后首次有效 |
| B 握手 | RAM 端和桥端实际接受响应的边沿 |
| 桥响应完成 | 桥→Cache（或直连 CPU）响应握手 |
| CPU 响应完成 | CPU `mem_rsp_fire`，错误独立分类 |
| STORE 退休 | NBA 后 `retire_valid` 及匹配的 `wb_pc` |

AW 与 W 各只记录一次，配对时间为 `max(AW, W)`。首次 BVALID 与实际 B 握手分别记录，因此背压不会被误算为 RAM 生成响应的时间。CPU 在成功响应握手边沿更新退休输出，两个时间戳可相同。

用于端到端加总的链条依次为：发起→CPU 接受→桥接受→上游配对→下游配对→RAM 提交→RAM 首次 BVALID→路由器首次 BVALID→桥首次 BVALID→B 握手→桥响应握手→CPU 响应握手→退休。12 个相邻差值在汇总中标为 `additive`。其它跨度如单通道等待、AW/W 间距、配对到首次响应，标为 `diagnostic`，不能再次叠加进该链。`launch_to_retire` 本身也属于重复跨度。

## 覆盖与输出

同一指令序列在 Cache 关闭／开启各运行一次，共五对场景：零等待、AW 先到、W 先到、AW/W 同拍且有 B 生成延迟、B 背压。B 背压由 testbench 同步屏蔽通道两侧的握手实现，保持实际接收方 READY 与发送方 VALID 对称，避免只屏蔽一侧造成重复响应。该注入使 RAM／路由器响应先有效、桥侧稍后可见，因此额外等待归入 `router_b_first_to_bridge_b_first`；RAM 端确实观察到 BVALID 保持而 BREADY 拉低。桥本身的正常 BREADY 策略没有改变。

初始 LOAD 建立 Cache 命中条件，随后执行 6 笔命中行 STORE，包含字节／半字写及重复地址写入，再对 `BASE+32` 执行 1 笔冷行 STORE。检查真实 lookup miss 及写后不分配。每场景另有 2 笔共享复位取消（AXI 发出前、RAM 已提交而 B 尚未接受）和 1 笔未映射 STORE 错误。后者不得写 RAM 或退休；提交后取消的 RAM 内容必须保留。每场景合计 8 次真实 RAM 写入，逐拍检查全部 RAM 内容及最终独立期望常量。

夹具采用小容量以方便逐拍检查：D-cache 为 2 组、2 路、4 字／行，RAM 为 16 字，路由窗口为 64 字节；CPU 直接连接相同请求／响应接口，指令端点使用 testbench 内置 ROM。被测 RTL 状态机与主工程相同；该设置用于测量单笔事务阶段延迟，不用于测量正式 2 KiB Cache 的容量收益或程序命中率。

每个场景输出 `build/axi_write_profile_<ID>_transactions.csv` 和 `build/axi_write_profile_<ID>_summary.csv`，ID 0～9 对应上述五对（偶数关闭 D-cache，奇数开启）。逐事务文件保留原始边沿；`-1` 表示该事件未发生，`epoch` 区分共享复位后的启动，`cache_hit` 是实际 Cache lookup（直连或非 RAM 地址为 `-1`）。`ram_effects` 表示这笔事务是否已真实写入，`data_write_wait` 按 CPU 内部写阻塞条件逐拍累计。

汇总文件有 27 行指标，给出 `count`、`min_cycles`、`max_cycles`、`mean_cycles`、`total_cycles`，仅纳入成功事务。取消和错误事务单独记录，不进入成功事务的延迟平均值。波形为 `build/axi_write_profile.wlf`，记录完整层次，默认展示零等待两配置及 Cache 开启的 B 背压场景。重新运行会覆盖这些固定名称，保存对比数据前应归档本轮文件。

这些是定向 STORE 通路的周期测量，不能直接按比例换算 CoreMark 的 `data_write_wait`。后者还包含真实程序中的 Cache 状态、请求阻塞和统计窗口边界。当前结果用于定位固定状态等待和外部背压，不代表上板成绩。

## 验证记录

2026-10-16，最终运行 `20261016T141208Z_e0b015bb0549`，ModelSim SE-64 10.6e 实际仿真通过：新平台 10 场景全部 PASS，新增平台编译／仿真均为 0 Error、0 Warning；同组既有 7 个 AXI 平台全部 PASS。输入运行前后哈希不变，RTL 与主工程保持逐字节一致，未修改硬件实现。

成功事务的 STORE 发起→退休结果如下；每个单独场景的 7 笔事务具有相同延迟，所以最小、最大和平均值相等。Cache 开启时包含 6 笔写命中和 1 笔写缺失。

| 场景（ID 对） | 注入等待 | Cache 关闭，周期 | Cache 开启，周期 |
| --- | --- | ---: | ---: |
| 零等待（0/1） | 无 | 5 | 7 |
| AW 先到（2/3） | 上游 W 延后 2 拍；RAM W 接受等待 3 拍 | 10 | 12 |
| W 先到（4/5） | 上游 AW 延后 2 拍；RAM AW 接受等待 3 拍 | 10 | 12 |
| AW/W 同拍、有等待（6/7） | RAM AW/W 各等待 2 拍；`B_WAIT=2` | 10 | 12 |
| B 背压（8/9） | 额外保持 B 4 拍 | 9 | 11 |

零等待 12 段的实测均值如下。0 周期表示同一边沿的不同事件，包含 NBA 前后采样口径。

| 汇总指标 | Cache 关闭 | Cache 开启 |
| --- | ---: | ---: |
| `launch_to_cpu_accept` | 0 | 0 |
| `cpu_accept_to_bridge_accept` | 0 | 1 |
| `bridge_accept_to_up_pair` | 1 | 1 |
| `up_pair_to_down_pair` | 1 | 1 |
| `down_pair_to_ram_commit` | 1 | 1 |
| `ram_commit_to_ram_b_first` | 0 | 0 |
| `ram_b_first_to_router_b_first` | 0 | 0 |
| `router_b_first_to_bridge_b_first` | 0 | 0 |
| `bridge_b_first_to_b_handshake` | 1 | 1 |
| `b_handshake_to_bridge_rsp` | 1 | 1 |
| `bridge_rsp_to_cpu_rsp` | 0 | 1 |
| `cpu_rsp_to_retire` | 0 | 0 |
| 合计 | **5** | **7** |

RAM 的零等待首次 BVALID 在下游请求配对后 1 拍出现，与真实提交同边沿；`B_WAIT=2` 时为配对后 4 拍。Cache 通路多出的 2 拍分别位于接受请求后的转交和桥响应后的返回。本测试中 STORE 的 CPU 响应和退休同边沿；每笔 `data_write_wait` 等于发起到响应的跨度。这些数据先用于评估两处 Cache 状态转换及桥的返回路径，后续仍需结合真实程序分布选择优化，当前保留 RTL。

本轮归档：`build/verification/axi_write_profile_20261016/`，包含逐事务及汇总 CSV、`analysis.json`、可重跑的 CSV 复核脚本、本轮统一回归日志／输入身份以及 `installation.json`。共核对 70 笔成功、20 笔取消、10 笔错误和 80 次 RAM 副作用；独立 CSV 复核检查配对时间、12 段加总、min/max/mean/count、成功／错误／取消隔离和真实副作用数量。
