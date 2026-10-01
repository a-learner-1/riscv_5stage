# Run after cd to the project directory.
catch {quit -sim}
if {![file exists work]} {vlib work}
vmap work work
vlog -sv -work work rtl/instr_mem.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v rtl/uart_tx.v rtl/gpio_mmio.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/cpu_top.v tb/jump_tb.v
vsim -voptargs=+acc -onfinish stop -wlf cpu_jump_run.wlf work.jump_tb
add wave sim:/jump_tb/clk sim:/jump_tb/rst_n
add wave sim:/jump_tb/pc_x sim:/jump_tb/instr_x sim:/jump_tb/valid_x
add wave sim:/jump_tb/wb_pc sim:/jump_tb/wb_rd sim:/jump_tb/wb_data sim:/jump_tb/wb_we
add wave sim:/jump_tb/dut/is_jal_x sim:/jump_tb/dut/is_jalr_x
add wave sim:/jump_tb/dut/imm_j_x sim:/jump_tb/dut/imm_x
add wave sim:/jump_tb/dut/jump_target_x sim:/jump_tb/dut/redirect_x
add wave sim:/jump_tb/dut/forward_rs1_x sim:/jump_tb/dut/forward_rs2_x
run -all
wave zoom full
