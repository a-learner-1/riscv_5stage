quit -sim
if {![file exists programs/c_demo.hex]} {
    error "programs/c_demo.hex is missing; run make or build_program.bat first"
}
if {![file exists programs/c_demo_data.hex]} {
    error "programs/c_demo_data.hex is missing; run make or build_program.bat first"
}
if {[file exists work]} {vdel -lib work -all}
vlib work
vmap work work

vlog -reportprogress 300 -sv -work work \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v \
    rtl/alu.v rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/gpio_mmio.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/rv32m_unit.v rtl/cpu_top.v tb/performance_tb.v

vsim -voptargs="+acc" -onfinish stop -wlf performance_run.wlf work.performance_tb
add wave sim:/performance_tb/clk
add wave sim:/performance_tb/rst_n
add wave -radix hexadecimal sim:/performance_tb/pc_x
add wave -radix hexadecimal sim:/performance_tb/instr_x
add wave sim:/performance_tb/valid_x
add wave -radix hexadecimal sim:/performance_tb/wb_pc
add wave sim:/performance_tb/retire_valid
add wave -radix unsigned sim:/performance_tb/cycle_count
add wave -radix unsigned sim:/performance_tb/instret_count
add wave -radix hexadecimal sim:/performance_tb/dut/mem_addr_x
add wave -radix hexadecimal sim:/performance_tb/dut/mem_wdata_x
add wave sim:/performance_tb/dut/mem_we_x
add wave -radix unsigned sim:/performance_tb/dut/u_data_mem/mem(4095)

run -all
wave zoom full
