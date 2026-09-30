quit -sim
if {[file exists work]} {vdel -lib work -all}
vlib work
vmap work work

vlog -reportprogress 300 -sv -work work \
    rtl/instr_mem.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v \
    rtl/alu.v rtl/data_mem.v rtl/uart_tx.v rtl/cpu_top.v tb/toolchain_program_tb.v

vsim -voptargs="+acc" -onfinish stop -wlf toolchain_program_run.wlf work.toolchain_program_tb
add wave sim:/toolchain_program_tb/clk
add wave sim:/toolchain_program_tb/rst_n
add wave -radix hexadecimal sim:/toolchain_program_tb/pc_x
add wave -radix hexadecimal sim:/toolchain_program_tb/instr_x
add wave sim:/toolchain_program_tb/valid_x
add wave -radix hexadecimal sim:/toolchain_program_tb/wb_pc
add wave -radix unsigned sim:/toolchain_program_tb/wb_rd
add wave -radix hexadecimal sim:/toolchain_program_tb/wb_data
add wave sim:/toolchain_program_tb/wb_we
add wave -radix hexadecimal sim:/toolchain_program_tb/dut/mem_addr_x
add wave -radix hexadecimal sim:/toolchain_program_tb/dut/mem_wdata_x
add wave -radix hexadecimal sim:/toolchain_program_tb/dut/mem_wstrb_x
add wave sim:/toolchain_program_tb/dut/mem_we_x
add wave sim:/toolchain_program_tb/dut/forward_rs1_x
add wave sim:/toolchain_program_tb/dut/forward_rs2_x
add wave -radix unsigned sim:/toolchain_program_tb/dut/u_data_mem/mem(255)

run -all
wave zoom full
