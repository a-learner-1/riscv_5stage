onerror {quit -code 1 -f}
catch {quit -sim}
foreach image {c_demo.hex c_demo_data.hex data_handshake_blank.hex uart_rx_echo.hex uart_rx_echo_data.hex board_demo.hex board_demo_sim_data.hex} {
    if {![file exists programs/$image]} {error "Missing existing programs/$image"}
}
if {![file exists modelsim.ini]} {vmap -c}
set soc_lib soc_work
if {![file exists $soc_lib]} {vlib $soc_lib}
vmap $soc_lib $soc_lib
vlog -sv -work $soc_lib \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v \
    rtl/regfile.v rtl/decoder.v rtl/alu.v \
    rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/uart_rx.v \
    rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/gpio_mmio.v rtl/cpu_top.v \
    rtl/soc_instr_mem.v rtl/soc_data_mem.v rtl/soc_top.v \
    rtl/board_reset.v rtl/soc_board_top.v \
    tb/soc_memory_tb.v tb/soc_top_tb.v tb/soc_board_tb.v tb/soc_fault_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf soc_memory_run.wlf $soc_lib.soc_memory_tb
run -all
if {[examine -radix unsigned sim:/soc_memory_tb/test_pass] != 1} {
    error "SoC memory endpoint test stopped without PASS"
}
quit -sim
vsim -voptargs="+acc" -onfinish stop -wlf soc_fault_run.wlf $soc_lib.soc_fault_tb
run -all
if {[examine -radix unsigned sim:/soc_fault_tb/test_pass] != 1} {
    error "SoC fault test stopped without PASS"
}
quit -sim
vsim -voptargs="+acc" -onfinish stop -wlf soc_board_run.wlf $soc_lib.soc_board_tb
run -all
if {[examine -radix unsigned sim:/soc_board_tb/test_pass] != 1} {
    error "SoC board test stopped without PASS"
}
quit -sim
vsim -voptargs="+acc" -onfinish stop -wlf soc_run.wlf $soc_lib.soc_top_tb
add wave sim:/soc_top_tb/done
add wave sim:/soc_top_tb/test_pass
add wave sim:/soc_top_tb/directed_wait/clk
add wave sim:/soc_top_tb/directed_wait/rst_n
add wave sim:/soc_top_tb/directed_wait/dut/imem_req_valid
add wave sim:/soc_top_tb/directed_wait/dut/imem_req_ready
add wave -radix hexadecimal sim:/soc_top_tb/directed_wait/dut/imem_req_addr
add wave sim:/soc_top_tb/directed_wait/dut/imem_rsp_valid
add wave sim:/soc_top_tb/directed_wait/dut/imem_rsp_ready
add wave -radix hexadecimal sim:/soc_top_tb/directed_wait/dut/imem_rsp_rdata
add wave sim:/soc_top_tb/directed_wait/dut/dmem_req_valid
add wave sim:/soc_top_tb/directed_wait/dut/dmem_req_ready
add wave sim:/soc_top_tb/directed_wait/dut/dmem_req_write
add wave -radix hexadecimal sim:/soc_top_tb/directed_wait/dut/dmem_req_addr
add wave -radix hexadecimal sim:/soc_top_tb/directed_wait/dut/dmem_req_wdata
add wave sim:/soc_top_tb/directed_wait/dut/dmem_req_wstrb
add wave sim:/soc_top_tb/directed_wait/dut/dmem_rsp_valid
add wave sim:/soc_top_tb/directed_wait/dut/dmem_rsp_ready
add wave -radix hexadecimal sim:/soc_top_tb/directed_wait/dut/dmem_rsp_rdata
add wave sim:/soc_top_tb/directed_wait/retire_valid
add wave -radix hexadecimal sim:/soc_top_tb/directed_wait/wb_pc
add wave sim:/soc_top_tb/directed_wait/imem_fault
add wave sim:/soc_top_tb/directed_wait/dmem_fault
add wave -radix unsigned sim:/soc_top_tb/c_fast/cycle_count
add wave -radix unsigned sim:/soc_top_tb/c_fast/instret_count
run -all
if {[examine -radix unsigned sim:/soc_top_tb/test_pass] != 1} {
    error "SoC integration test stopped without PASS"
}
catch {wave zoom full}
