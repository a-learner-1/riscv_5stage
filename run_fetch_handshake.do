onerror {quit -code 1 -f}
catch {quit -sim}
if {![file exists programs/data_handshake_blank.hex]} {
    error "Missing programs/data_handshake_blank.hex"
}
if {![file exists modelsim.ini]} {vmap -c}
set fetch_lib fetch_handshake_work
if {![file exists $fetch_lib]} {vlib $fetch_lib}
vmap $fetch_lib $fetch_lib
vlog -sv -work $fetch_lib \
    rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v \
    rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v \
    rtl/data_bus_adapter.v rtl/gpio_mmio.v rtl/rv32m_unit.v rtl/cpu_top.v \
    tb/fetch_handshake_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf fetch_handshake_run.wlf $fetch_lib.fetch_handshake_tb
add wave sim:/fetch_handshake_tb/done
add wave sim:/fetch_handshake_tb/test_pass
add wave sim:/fetch_handshake_tb/external_random/clk
add wave sim:/fetch_handshake_tb/external_random/rst_n
add wave sim:/fetch_handshake_tb/external_random/req_valid
add wave sim:/fetch_handshake_tb/external_random/req_ready
add wave -radix hexadecimal sim:/fetch_handshake_tb/external_random/req_addr
add wave sim:/fetch_handshake_tb/external_random/rsp_valid
add wave sim:/fetch_handshake_tb/external_random/rsp_ready
add wave -radix hexadecimal sim:/fetch_handshake_tb/external_random/rsp_rdata
add wave sim:/fetch_handshake_tb/external_random/dut/stall_x
add wave sim:/fetch_handshake_tb/external_random/dut/redirect_x
add wave sim:/fetch_handshake_tb/external_random/retire_valid
add wave -radix hexadecimal sim:/fetch_handshake_tb/external_random/wb_pc
add wave sim:/fetch_handshake_tb/blocked_redirect/req_valid
add wave sim:/fetch_handshake_tb/blocked_redirect/req_ready
add wave -radix hexadecimal sim:/fetch_handshake_tb/blocked_redirect/req_addr
add wave sim:/fetch_handshake_tb/blocked_redirect/dut/redirect_x
add wave sim:/fetch_handshake_tb/stale_error/rsp_error
add wave sim:/fetch_handshake_tb/stale_error/imem_fault
add wave sim:/fetch_handshake_tb/reset_fault/rst_n
add wave sim:/fetch_handshake_tb/reset_fault/imem_fault
add wave -radix hexadecimal sim:/fetch_handshake_tb/reset_fault/fault_pc
add wave sim:/fetch_handshake_tb/frontend_boundary/local_fault
add wave -radix hexadecimal sim:/fetch_handshake_tb/frontend_boundary/local_fault_pc
add wave sim:/fetch_handshake_tb/frontend_boundary/external_redirect
add wave sim:/fetch_handshake_tb/frontend_boundary/external_rsp_error
add wave sim:/fetch_handshake_tb/frontend_boundary/external_fault
run -all
if {[examine -radix unsigned sim:/fetch_handshake_tb/test_pass] != 1} {
    error "Fetch handshake test stopped without PASS"
}
catch {wave zoom full}
