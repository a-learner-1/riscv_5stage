# Prepared future acceptance entry; do not interpret this file as a test result.
onerror {quit -code 1 -f}
catch {quit -sim}
foreach image {machine_irq_board.hex machine_irq_board_data.hex machine_irq_board_sim_data.hex machine_irq_board_symbols.vh} {
    if {![file exists programs/$image]} {error "Missing programs/$image; first run build_machine_irq_board.bat when validation is authorized"}
}
foreach source {tools/machine_irq_contract.py rtl/branch_predictor.v rtl/axi_lite_irq_demo.v rtl/machine_irq_board_top.v tb/machine_irq_board_tb.v} {
    if {![file exists $source]} {error "Missing $source; install the complete machine IRQ source step"}
}
# The guard validates current source and image hashes, generated observation
# addresses and the single allowed heartbeat-word difference. It does not build.
if {[catch {exec python tools/machine_irq_contract.py --simulation} guard_output]} {
    error "Machine IRQ simulation image contract rejected the inputs: $guard_output"
}
echo $guard_output
if {![file exists modelsim.ini]} {vmap -c}
if {![file exists build]} {file mkdir build}
if {![file exists machine_irq_board_work]} {vlib machine_irq_board_work}
vmap machine_irq_board_work machine_irq_board_work
vlog -sv -work machine_irq_board_work \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v \
    rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v rtl/data_bus_adapter.v \
    rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/gpio_mmio.v \
    rtl/machine_timer.v rtl/rv32m_unit.v rtl/cpu_top.v rtl/board_reset.v rtl/soc_instr_mem.v \
    rtl/instr_cache.v rtl/data_cache.v rtl/dmem_axi_lite_bridge.v \
    rtl/axi_lite_1x2.v rtl/axi_lite_ram.v rtl/axi_lite_irq_demo.v \
    rtl/soc_axi_lite_top.v rtl/machine_irq_board_top.v tb/machine_irq_board_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/machine_irq_board_run.wlf machine_irq_board_work.machine_irq_board_tb
add wave sim:/machine_irq_board_tb/test_pass
add wave -radix hexadecimal sim:/machine_irq_board_tb/done
foreach signal {clk key1_n boots led tx traps mrets work_writes checksum_writes in_isr in_work zero_tohost_writes terminal_writes terminal_value} {
    add wave sim:/machine_irq_board_tb/normal/$signal
}
foreach signal {cpu_rst_n irq_external trap_valid trap_pc trap_cause trap_tval imem_fault dmem_fault} {
    add wave -radix hexadecimal sim:/machine_irq_board_tb/normal/dut/$signal
}
foreach signal {csr_mstatus csr_mie csr_mip_value csr_mepc external_irq_meta external_irq_sync software_msip timer_mtip irq_selected_cause} {
    add wave -radix hexadecimal sim:/machine_irq_board_tb/normal/dut/u_soc/u_cpu/$signal
}
foreach signal {pending set_count clear_count} {
    add wave -radix unsigned sim:/machine_irq_board_tb/normal/dut/u_irq_source/$signal
}
add wave sim:/machine_irq_board_tb/reset_handler/key1_n
add wave sim:/machine_irq_board_tb/software_fail/led
run -all
if {[examine -radix unsigned sim:/machine_irq_board_tb/test_pass] != 1} {
    error "Machine IRQ board simulation stopped without test_pass=1"
}
echo "Machine IRQ board test_pass=1"
catch {wave zoom full}
