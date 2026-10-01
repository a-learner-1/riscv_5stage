onerror {quit -code 1 -f}
catch {quit -sim}
if {![file exists programs/data_handshake_blank.hex]} {
    error "Missing programs/data_handshake_blank.hex"
}
if {![file exists modelsim.ini]} {vmap -c}
set handshake_lib data_handshake_work
if {![file exists $handshake_lib]} {vlib $handshake_lib}
vmap $handshake_lib $handshake_lib
vlog -sv -work $handshake_lib \
    rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v \
    rtl/instr_mem.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v \
    rtl/data_mem.v rtl/data_bus_adapter.v rtl/gpio_mmio.v rtl/cpu_top.v \
    tb/data_bus_adapter_tb.v tb/data_handshake_tb.v
vsim -voptargs="+acc" -onfinish stop $handshake_lib.data_bus_adapter_tb
run -all
if {[examine -radix unsigned sim:/data_bus_adapter_tb/test_pass] != 1} {
    error "Data adapter unit check stopped without PASS"
}
quit -sim
vsim -voptargs="+acc" -onfinish stop -wlf data_handshake_run.wlf data_handshake_work.data_handshake_tb
add wave sim:/data_handshake_tb/done
add wave sim:/data_handshake_tb/test_pass
add wave sim:/data_handshake_tb/ram_random/clk
add wave sim:/data_handshake_tb/ram_random/rst_n
add wave sim:/data_handshake_tb/ram_random/req_valid
add wave sim:/data_handshake_tb/ram_random/req_ready
add wave sim:/data_handshake_tb/ram_random/req_write
add wave -radix hexadecimal sim:/data_handshake_tb/ram_random/req_addr
add wave -radix hexadecimal sim:/data_handshake_tb/ram_random/req_wdata
add wave sim:/data_handshake_tb/ram_random/req_wstrb
add wave sim:/data_handshake_tb/ram_random/rsp_valid
add wave sim:/data_handshake_tb/ram_random/rsp_ready
add wave -radix hexadecimal sim:/data_handshake_tb/ram_random/rsp_rdata
add wave sim:/data_handshake_tb/ram_random/dut/load_pending
add wave sim:/data_handshake_tb/ram_random/retire_valid
add wave -radix hexadecimal sim:/data_handshake_tb/ram_random/wb_pc
add wave sim:/data_handshake_tb/mmio_wait/dut/mem_req_fire
add wave sim:/data_handshake_tb/mmio_wait/dut/mem_rsp_fire
add wave -radix unsigned sim:/data_handshake_tb/mmio_wait/real_pops
add wave -radix unsigned sim:/data_handshake_tb/mmio_wait/gpio_toggle_writes
add wave sim:/data_handshake_tb/reset_error/fault
run -all
if {[examine -radix unsigned sim:/data_handshake_tb/test_pass] != 1} {
    error "Data handshake test stopped without PASS"
}
catch {wave zoom full}
