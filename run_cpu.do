# Run after cd to the project directory.
catch {quit -sim}
if {![file exists work]} {vlib work}
vmap work work
vlog -sv -work work rtl/instr_mem.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v rtl/uart_tx.v rtl/cpu_top.v tb/alu_tb.v tb/decoder_tb.v tb/if_stage_tb.v tb/cpu_top_tb.v
vsim -voptargs=+acc -onfinish stop -wlf cpu_upper_imm_run.wlf work.cpu_top_tb
add wave sim:/cpu_top_tb/clk sim:/cpu_top_tb/rst_n
add wave sim:/cpu_top_tb/pc_x sim:/cpu_top_tb/instr_x
add wave sim:/cpu_top_tb/wb_pc sim:/cpu_top_tb/wb_rd sim:/cpu_top_tb/wb_data sim:/cpu_top_tb/wb_we
add wave sim:/cpu_top_tb/dut/use_shift_imm_x sim:/cpu_top_tb/dut/shamt_imm_x
add wave sim:/cpu_top_tb/dut/use_upper_imm_x sim:/cpu_top_tb/dut/imm_u_x
add wave sim:/cpu_top_tb/dut/is_lui_x sim:/cpu_top_tb/dut/is_auipc_x
add wave sim:/cpu_top_tb/dut/forward_rs1_x sim:/cpu_top_tb/dut/forward_rs2_x
add wave sim:/cpu_top_tb/dut/alu_op_x sim:/cpu_top_tb/dut/alu_a_x sim:/cpu_top_tb/dut/alu_b_x sim:/cpu_top_tb/dut/alu_result_x
run -all
wave zoom full
