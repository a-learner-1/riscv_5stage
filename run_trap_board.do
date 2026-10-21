onerror {quit -code 1 -f}
catch {quit -sim}
foreach image {trap_board.hex trap_board_data.hex trap_board_sim_data.hex trap_board_symbols.vh} {
    if {![file exists programs/$image]} {error "Missing programs/$image; run build_trap_board.bat"}
}
if {![file exists modelsim.ini]} {vmap -c}
if {![file exists trap_board_work]} {vlib trap_board_work}
vmap trap_board_work trap_board_work
vlog -sv -work trap_board_work \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v \
    rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v \
    rtl/uart_rx_mmio.v rtl/gpio_mmio.v rtl/rv32m_unit.v rtl/cpu_top.v rtl/board_reset.v rtl/soc_instr_mem.v \
    rtl/dmem_axi_lite_bridge.v rtl/axi_lite_ram.v rtl/soc_axi_lite_top.v rtl/trap_board_top.v \
    tb/trap_board_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf trap_board_run.wlf trap_board_work.trap_board_tb
add wave sim:/trap_board_tb/test_pass
add wave -radix hexadecimal sim:/trap_board_tb/done
foreach signal {clk key1_n boots led tx traps mrets fences} {
    add wave sim:/trap_board_tb/normal/$signal
}
foreach signal {cpu_rst_n trap_valid trap_pc trap_cause trap_tval imem_fault dmem_fault} {
    add wave -radix hexadecimal sim:/trap_board_tb/normal/dut/$signal
}
add wave sim:/trap_board_tb/normal/dut/u_soc/u_cpu/csr_mstatus
add wave sim:/trap_board_tb/normal/dut/u_soc/u_cpu/csr_mtvec
add wave sim:/trap_board_tb/normal/dut/u_soc/u_cpu/csr_mepc
add wave sim:/trap_board_tb/reset_handler/key1_n
add wave sim:/trap_board_tb/reset_handler/dut/trap_valid
add wave sim:/trap_board_tb/software_fail/led
run -all
if {[examine -radix unsigned sim:/trap_board_tb/test_pass] != 1} {
    error "Trap board stopped without PASS"
}
echo "Trap board test_pass=1"
catch {wave zoom full}
