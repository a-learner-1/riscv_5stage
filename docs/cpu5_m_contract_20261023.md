# CPU5 RV32M / owner 本轮合同

2026-10-23，基线 `3d2644e248347429610ca46a555c2ed361c6e9ae`。本轮独立实现 M owner 与八种 RV32M 运算；IRQ、MMIO、FENCE、正式SoC/板顶/性能均不在范围。原 `rv32m_unit.v`、三级产品、已冻结报告与用户未提交工作保持原样。

- 新 `ENABLE_RV32M=0` 默认关闭。top 历史 `ENABLE_M=1` 自身仍不启动M；显式打开新参数才接入。top不允许 `ENABLE_RV32M=1` 且 `ENABLE_M=0`，也不允许metadata骨架打开M。core参数必须布尔。CSR bank 的 misa 仅在实际接入时返回40001100，否则40000100；写仍合法忽略，不作完整ISA合规结论。
- opcode=33且funct7=01的八种funct3对应MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU；除零/有符号溢出是正常定义结果，不取Trap。结果绑定同一PC/instr/64位seq/op，EX传入MEM，唯一MEM退休，WB与现有前递路径写一次。
- 首版保守启动门：live EX M、操作数已就绪、ex_enable、无flush/胜出Trap/MRET，且老MEM没有访存、CSR/MRET或fault风险，方可呈现issue。老普通ALU的WB回压可与年轻M运算重叠，但不能提前退休M。未知/被取消M零启动或在已启动后仅排空。
- `issue_fire`在同一边沿真正start原M单元并绑定唯一owner。owner未释放前不接受新start，不同owner不做同拍交接。Fetch epoch仅追溯，不决定M存活。kill使用无符号64位seq和第一条被取消的cut。
- 代际64位不回卷，全1保留耗尽标记；默认从0分配，仿真遇耗尽拒绝继续，需reset。`RESET_GENERATION`仅是owner测试/参数化初始值，用来无force验证跨bit32与真实耗尽，不缩窄真实位宽。
- start边沿不能消费旧sticky done；下一边沿起才检查当前owner的结果，无需先看busy=1或done=0。快路径start后done=1/busy=0也必须正常完成。新结果的generation与owner一致；live结果可持有至EX允许转级，不能重复消费。
- killed owner保持原单元运行，结果出现时自动drain/drop一次，零GPR/退休/CSR/BP。后台busy只阻止新M；冲刷后独立ALU/CSR与Trap入口可以推进，新M必须等旧owner排空后发新代际。该取消过程不修改原单元、不承诺硬件cancel。
- 保守配置的真实 `old LOAD fault + young DIV` 预期DIV未启动；不把它写为运行DIV被LOAD故障取消。运行中DIV取消以外部年龄flush定向验证，新路径ALU/CSR及M资源恢复须闭合。未来开放访存/M重叠或IRQ时再补真实运行中故障/IRQ场景。

依据：`cpu5_design_contract_20261021.md` §§3/5、冻结v0.3 §6.1、原 `rv32m_unit.v`。正常MUL的unit post-edge done为start+2，普通DIV/REM为+32，除零/有符号溢出同start边沿后完成；这些旧unit事实不等于CPU5退休延迟，集成延迟只按本轮实测。A14仅验收本阶段可达子句；IRQ/A16与完整系统签核仍未实现/未运行。

算术语义核对：[RISC-V M扩展规范](https://docs.riscv.org/reference/isa/v20240411/unpriv/m-st-ext.html)。有符号商向零舍入，非零余数随被除数符号；除零商全1、余数为被除数；INT_MIN/-1商为INT_MIN、余数0。
