onerror {quit -code 1 -f}
catch {quit -sim}
if {![file exists modelsim.ini]} {vmap -c}
if {![file exists trap_work]} {vlib trap_work}
vmap trap_work trap_work
vlog -sv -work trap_work \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v \
    rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v \
    rtl/uart_rx_mmio.v rtl/gpio_mmio.v rtl/rv32m_unit.v rtl/cpu_top.v tb/cpu_trap_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf trap_run.wlf trap_work.cpu_trap_tb
add wave sim:/cpu_trap_tb/test_pass
add wave -radix hexadecimal sim:/cpu_trap_tb/done
foreach testcase {csr_fast local_wait external_random fetch_random} {
    foreach signal {clk rst_n retire_valid trap_valid wb_pc wb_rd wb_data trap_pc trap_cause trap_tval instret_count} {
        add wave sim:/cpu_trap_tb/$testcase/$signal
    }
}
foreach signal {ir_valid ir_ready ir_addr is_valid is_ready is_error dr_valid dr_ready dr_addr ds_valid ds_ready ds_error} {
    add wave sim:/cpu_trap_tb/fetch_random/$signal
}
run -all
if {[examine -radix unsigned sim:/cpu_trap_tb/test_pass] != 1} {error "Trap tests stopped without PASS"}
echo "CPU trap test_pass=1"
catch {wave zoom full}
