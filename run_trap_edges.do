onerror {quit -code 1 -f}
catch {quit -sim}
if {![file exists modelsim.ini]} {vmap -c}
if {![file exists trap_edges_work]} {vlib trap_edges_work}
vmap trap_edges_work trap_edges_work
vlog -sv -work trap_edges_work \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v \
    rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v \
    rtl/uart_rx_mmio.v rtl/gpio_mmio.v rtl/cpu_top.v tb/cpu_trap_edges_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf trap_edges_run.wlf trap_edges_work.cpu_trap_edges_tb
add wave sim:/cpu_trap_edges_tb/test_pass
add wave -radix hexadecimal sim:/cpu_trap_edges_tb/done
foreach testcase {local_fetch_wait priority_random} {
    foreach signal {clk rst_n retire_valid trap_valid wb_pc wb_data trap_pc trap_cause trap_tval instret_count} {
        add wave sim:/cpu_trap_edges_tb/$testcase/$signal
    }
}
foreach signal {ir_valid ir_ready ir_addr is_valid is_ready is_error dr_valid dr_ready dr_addr ds_valid ds_ready ds_error} {
    add wave sim:/cpu_trap_edges_tb/priority_random/$signal
}
run -all
if {[examine -radix unsigned sim:/cpu_trap_edges_tb/test_pass] != 1} {error "Trap edge tests stopped without PASS"}
echo "CPU trap edge test_pass=1"
catch {wave zoom full}
