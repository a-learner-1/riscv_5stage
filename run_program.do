quit -sim
if {[file exists work]} {vdel -lib work -all}
vlib work
vmap work work
vlog -reportprogress 300 -sv -work work rtl/instr_mem.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v rtl/uart_tx.v rtl/gpio_mmio.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/cpu_top.v tb/instr_mem_tb.v tb/program_load_tb.v

vsim -voptargs=+acc -onfinish stop work.instr_mem_tb
run -all
quit -sim

vsim -voptargs=+acc -onfinish stop -wlf external_program_run.wlf work.program_load_tb
add wave sim:/program_load_tb/clk
add wave sim:/program_load_tb/rst_n
add wave sim:/program_load_tb/pc_x
add wave sim:/program_load_tb/instr_x
add wave sim:/program_load_tb/valid_x
add wave sim:/program_load_tb/wb_pc
add wave sim:/program_load_tb/wb_rd
add wave sim:/program_load_tb/wb_data
add wave sim:/program_load_tb/wb_we
add wave sim:/program_load_tb/dut/u_if_stage/pc_f
add wave sim:/program_load_tb/dut/u_if_stage/fetch_ok_f
add wave sim:/program_load_tb/dut/redirect_x
add wave sim:/program_load_tb/dut/redirect_pc_x
add wave sim:/program_load_tb/dut/mem_addr_x
add wave sim:/program_load_tb/dut/mem_wstrb_x
add wave sim:/program_load_tb/dut/load_data_x
add wave sim:/program_load_tb/dut/forward_rs1_x
add wave sim:/program_load_tb/dut/forward_rs2_x
run -all
wave zoom full
