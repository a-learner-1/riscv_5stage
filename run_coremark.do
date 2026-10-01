quit -sim
if {![file exists programs/coremark.hex]} {
    error "programs/coremark.hex is missing; run build_coremark.bat first"
}
if {![file exists programs/coremark_data.hex]} {
    error "programs/coremark_data.hex is missing; run build_coremark.bat first"
}
if {[file exists work]} {vdel -lib work -all}
vlib work
vmap work work

vlog -reportprogress 300 -sv -work work \
    rtl/instr_mem.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v \
    rtl/alu.v rtl/data_mem.v rtl/uart_tx.v rtl/gpio_mmio.v rtl/cpu_top.v tb/coremark_tb.v

vsim -voptargs="+acc" -onfinish stop -wlf coremark_run.wlf work.coremark_tb
add wave sim:/coremark_tb/clk
add wave sim:/coremark_tb/rst_n
add wave -radix hexadecimal sim:/coremark_tb/pc_x
add wave -radix hexadecimal sim:/coremark_tb/instr_x
add wave sim:/coremark_tb/valid_x
add wave sim:/coremark_tb/dut/load_pending
add wave -radix hexadecimal sim:/coremark_tb/dut/mem_addr_x
add wave sim:/coremark_tb/dut/mmio_putchar_valid
add wave -radix ascii sim:/coremark_tb/dut/mmio_putchar_data
add wave -radix unsigned sim:/coremark_tb/cycle_count
add wave -radix unsigned sim:/coremark_tb/instret_count
add wave -radix unsigned sim:/coremark_tb/dut/u_data_mem/mem(4095)

run -all
wave zoom full
