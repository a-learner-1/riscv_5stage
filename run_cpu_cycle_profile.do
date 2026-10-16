onerror {quit -code 1 -f}
catch {quit -sim}
if {![file exists programs/data_handshake_blank.hex]} {
    error "Missing programs/data_handshake_blank.hex"
}
if {![file exists modelsim.ini]} {vmap -c}
set profile_lib cpu_cycle_profile_work
if {![file exists $profile_lib]} {vlib $profile_lib}
vmap $profile_lib $profile_lib
vlog -sv -work $profile_lib \
    rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v \
    rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v \
    rtl/data_bus_adapter.v rtl/gpio_mmio.v rtl/machine_timer.v rtl/cpu_top.v \
    tb/cpu_cycle_profile_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf cpu_cycle_profile_run.wlf $profile_lib.cpu_cycle_profile_tb
add wave sim:/cpu_cycle_profile_tb/done sim:/cpu_cycle_profile_tb/test_pass
add wave sim:/cpu_cycle_profile_tb/on_waits/events
add wave -radix unsigned sim:/cpu_cycle_profile_tb/on_waits/cycle_count
add wave sim:/cpu_cycle_profile_tb/on_waits/dut/perf_redirect_pending
run -all
if {[examine -radix unsigned sim:/cpu_cycle_profile_tb/test_pass] != 1} {
    error "CPU cycle profile stopped without PASS"
}
catch {wave zoom full}
