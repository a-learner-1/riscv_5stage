onerror {quit -code 1 -f}
catch {quit -sim}
foreach image {axi_control_board.hex axi_control_board_data.hex axi_control_board_sim_data.hex} {
    if {![file exists programs/$image]} {error "Missing programs/$image; run build_axi_control_board.bat"}
}
if {![file exists modelsim.ini]} {vmap -c}
if {![file exists axi_control_board_work]} {vlib axi_control_board_work}
vmap axi_control_board_work axi_control_board_work
vlog -sv -work axi_control_board_work \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v \
    rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v \
    rtl/uart_rx_mmio.v rtl/gpio_mmio.v rtl/cpu_top.v rtl/board_reset.v rtl/soc_instr_mem.v \
    rtl/dmem_axi_lite_bridge.v rtl/axi_lite_ram.v rtl/soc_axi_lite_top.v \
    rtl/axi_lite_1x2.v rtl/axi_lite_ctrl.v rtl/soc_axi_control_top.v rtl/axi_control_board_top.v \
    tb/axi_control_board_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf axi_control_board_run.wlf axi_control_board_work.axi_control_board_tb
add wave sim:/axi_control_board_tb/test_pass
add wave -radix hexadecimal sim:/axi_control_board_tb/done
foreach signal {clk key1_n boots led tx start_writes} {
    add wave sim:/axi_control_board_tb/normal/$signal
}
foreach signal {cpu_rst_n imem_fault dmem_fault} {
    add wave sim:/axi_control_board_tb/normal/dut/$signal
}
foreach signal {ctrl_busy ctrl_done ctrl_result ctrl_start_count} {
    add wave sim:/axi_control_board_tb/normal/dut/u_soc/$signal
}
add wave sim:/axi_control_board_tb/software_fail/led
add wave sim:/axi_control_board_tb/data_fault/led
add wave sim:/axi_control_board_tb/fetch_fault/led
run -all
if {[examine -radix unsigned sim:/axi_control_board_tb/test_pass] != 1} {
    error "AXI control board stopped without PASS"
}
echo "AXI control board test_pass=1"
catch {wave zoom full}
