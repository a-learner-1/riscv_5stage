onerror {quit -code 1 -f}
catch {quit -sim}
foreach image {trap_demo.hex trap_demo_data.hex trap_demo_symbols.vh} {
    if {![file exists programs/$image]} {error "Missing $image; run build_trap.bat"}
}
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory trap_c_work]} {vlib trap_c_work}
vmap trap_c_work trap_c_work
vlog -sv -work trap_c_work rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v \
    rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v rtl/data_bus_adapter.v \
    rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/gpio_mmio.v \
    rtl/cpu_top.v rtl/soc_instr_mem.v rtl/dmem_axi_lite_bridge.v rtl/axi_lite_ram.v \
    rtl/soc_axi_lite_top.v tb/trap_c_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf trap_c_run.wlf trap_c_work.trap_c_tb
add wave sim:/trap_c_tb/test_pass
add wave -radix hexadecimal sim:/trap_c_tb/done
foreach signal {clk rst_n tx traps mrets fences bytes} {add wave sim:/trap_c_tb/aw_first/$signal}
foreach signal {trap_valid trap_pc trap_cause trap_tval wb_pc retire_valid} {
    add wave -radix hexadecimal sim:/trap_c_tb/aw_first/$signal
}
foreach signal {csr_mstatus csr_mtvec csr_mepc csr_mcause csr_mtval} {
    add wave -radix hexadecimal sim:/trap_c_tb/aw_first/dut/u_cpu/$signal
}
run -all
if {[examine -radix unsigned sim:/trap_c_tb/test_pass] != 1} {error "Trap C stopped without PASS"}
echo "Trap C test_pass=1"
catch {wave zoom full}
