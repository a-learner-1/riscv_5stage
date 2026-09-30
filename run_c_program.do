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
    rtl/instr_mem.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v \
    rtl/alu.v rtl/data_mem.v rtl/uart_tx.v rtl/cpu_top.v tb/c_program_tb.v

vsim -voptargs="+acc" -onfinish stop -wlf c_program_run.wlf work.c_program_tb
add wave sim:/c_program_tb/clk
add wave sim:/c_program_tb/rst_n
add wave -radix hexadecimal sim:/c_program_tb/pc_x
add wave -radix hexadecimal sim:/c_program_tb/instr_x
add wave sim:/c_program_tb/valid_x
add wave -radix hexadecimal sim:/c_program_tb/wb_pc
add wave -radix unsigned sim:/c_program_tb/wb_rd
add wave -radix hexadecimal sim:/c_program_tb/wb_data
add wave sim:/c_program_tb/wb_we
add wave -radix hexadecimal sim:/c_program_tb/dut/mem_addr_x
add wave -radix hexadecimal sim:/c_program_tb/dut/mem_wdata_x
add wave -radix hexadecimal sim:/c_program_tb/dut/mem_wstrb_x
add wave sim:/c_program_tb/dut/mem_we_x
add wave -radix unsigned sim:/c_program_tb/dut/u_data_mem/mem(4095)

run -all
wave zoom full
