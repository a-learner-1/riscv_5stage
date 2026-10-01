# Run after cd to the project directory.
catch {quit -sim}
if {![file exists work]} {vlib work}
vmap work work
vlog -sv -work work rtl/instr_mem.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v rtl/uart_tx.v rtl/gpio_mmio.v rtl/cpu_top.v tb/compare_branch_tb.v
vsim -voptargs=+acc -onfinish stop -wlf cpu_compare_branch_run.wlf work.compare_branch_tb
add wave sim:/compare_branch_tb/clk sim:/compare_branch_tb/rst_n
add wave sim:/compare_branch_tb/pc_x sim:/compare_branch_tb/instr_x sim:/compare_branch_tb/valid_x
add wave sim:/compare_branch_tb/wb_pc sim:/compare_branch_tb/wb_rd sim:/compare_branch_tb/wb_data sim:/compare_branch_tb/wb_we
add wave sim:/compare_branch_tb/dut/is_blt_x sim:/compare_branch_tb/dut/is_bge_x
add wave sim:/compare_branch_tb/dut/is_bltu_x sim:/compare_branch_tb/dut/is_bgeu_x
add wave sim:/compare_branch_tb/dut/rs1_value_x sim:/compare_branch_tb/dut/rs2_value_x
add wave sim:/compare_branch_tb/dut/branch_taken_x sim:/compare_branch_tb/dut/branch_target_x
add wave sim:/compare_branch_tb/dut/forward_rs1_x sim:/compare_branch_tb/dut/forward_rs2_x
run -all
wave zoom full
