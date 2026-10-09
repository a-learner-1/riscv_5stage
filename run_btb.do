# Future regression entry. Prepared only; no simulation was run for this step.
onerror {quit -code 1 -f}
catch {quit -sim}
if {![file exists programs/data_handshake_blank.hex]} {
    error "Missing programs/data_handshake_blank.hex"
}
if {![file exists modelsim.ini]} {vmap -c}
set btb_lib btb_work
if {![file exists $btb_lib]} {vlib $btb_lib}
vmap $btb_lib $btb_lib
vlog -sv -work $btb_lib \
    rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v \
    rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v \
    rtl/data_bus_adapter.v rtl/gpio_mmio.v rtl/machine_timer.v rtl/cpu_top.v \
    tb/branch_predictor_tb.v tb/btb_cpu_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf btb_unit_run.wlf $btb_lib.branch_predictor_tb
add wave sim:/branch_predictor_tb/done sim:/branch_predictor_tb/test_pass
add wave -radix hexadecimal sim:/branch_predictor_tb/frontend_case/req_addr
add wave -radix hexadecimal sim:/branch_predictor_tb/frontend_case/pred_next
add wave sim:/branch_predictor_tb/frontend_case/req_valid
add wave sim:/branch_predictor_tb/frontend_case/req_ready
add wave sim:/branch_predictor_tb/frontend_case/redirect
add wave sim:/branch_predictor_tb/frontend_case/rsp_error
run -all
if {[examine -radix unsigned sim:/branch_predictor_tb/test_pass] != 1} {
    error "BTB unit test stopped without PASS"
}
quit -sim
vsim -voptargs="+acc" -onfinish stop -wlf btb_cpu_run.wlf $btb_lib.btb_cpu_tb
add wave sim:/btb_cpu_tb/done sim:/btb_cpu_tb/test_pass
add wave sim:/btb_cpu_tb/external_random/dut/stall_x
add wave sim:/btb_cpu_tb/external_random/dut/redirect_x
add wave -radix hexadecimal sim:/btb_cpu_tb/external_random/dut/pc_x
add wave -radix hexadecimal sim:/btb_cpu_tb/external_random/dut/predicted_next_pc_x
add wave sim:/btb_cpu_tb/external_random/retire_valid
add wave -radix hexadecimal sim:/btb_cpu_tb/external_random/wb_pc
run -all
if {[examine -radix unsigned sim:/btb_cpu_tb/test_pass] != 1} {
    error "BTB CPU test stopped without PASS"
}
catch {wave zoom full}
