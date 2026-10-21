# Deterministic port fixtures only. No benchmark score and no old regression.
onerror {quit -code 1 -f}
catch {quit -sim}
if {![file exists build]} {file mkdir build}
if {![file exists modelsim.ini]} {vmap -c}
if {![file exists coremark_port_math_work]} {vlib coremark_port_math_work}
vmap coremark_port_math_work coremark_port_math_work
vlog -sv +incdir+. -work coremark_port_math_work \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v \
    rtl/alu.v rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/gpio_mmio.v \
    rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/machine_timer.v rtl/rv32m_unit.v rtl/cpu_top.v \
    tb/coremark_port_math_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/coremark_port_math.wlf coremark_port_math_work.coremark_port_math_tb
add wave sim:/coremark_port_math_tb/test_pass
add wave sim:/coremark_port_math_tb/done
run -all
if {[examine -radix unsigned sim:/coremark_port_math_tb/test_pass] != 1} {error "CoreMark port math stopped without PASS"}
echo "COREMARK PORT MATH TESTS PASS"
catch {wave zoom full}
