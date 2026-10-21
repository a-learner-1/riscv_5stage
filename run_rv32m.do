# Run with: vsim -c -do "do run_rv32m.do; quit -f"
# Only this test's work library and generated build/rv32m files are written.
onerror {quit -code 1 -f}
catch {quit -sim}
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/rv32m]} {file mkdir build/rv32m}
exec python tools/generate_rv32m_vectors.py
if {![file isdirectory build/rv32m/work]} {vlib build/rv32m/work}
vmap rv32m_work build/rv32m/work
vlog -sv +incdir+. -work rv32m_work \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v \
    rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/rv32m_unit.v rtl/data_mem.v rtl/data_bus_adapter.v \
    rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v \
    rtl/gpio_mmio.v rtl/machine_timer.v rtl/cpu_top.v \
    tb/rv32m_unit_tb.v tb/rv32m_cpu_tb.v
foreach bench {rv32m_unit_tb rv32m_cpu_tb} {
    catch {quit -sim}
    vsim -voptargs=+acc -onfinish stop -wlf build/rv32m/${bench}.wlf rv32m_work.$bench
    run -all
    if {[examine -radix unsigned sim:/$bench/test_pass] != 1} {error "$bench stopped without PASS"}
    echo "$bench test_pass=1"
}
echo "RV32M DIRECTED AND RANDOM TESTS PASS"
unset -nocomplain bench
