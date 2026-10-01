# Run after cd to the project directory.
catch {quit -sim}
if {![file exists work]} {vlib work}
vmap work work
vlog -sv -work work rtl/instr_mem.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/gpio_mmio.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/cpu_top.v tb/branch_tb.v
vsim -voptargs=+acc -onfinish stop -wlf cpu_branch_run.wlf work.branch_tb
add wave sim:/branch_tb/clk sim:/branch_tb/rst_n
add wave sim:/branch_tb/pc_x sim:/branch_tb/instr_x sim:/branch_tb/valid_x
add wave sim:/branch_tb/wb_pc sim:/branch_tb/wb_rd sim:/branch_tb/wb_data sim:/branch_tb/wb_we
add wave sim:/branch_tb/dut/is_beq_x sim:/branch_tb/dut/is_bne_x
add wave sim:/branch_tb/dut/imm_b_x sim:/branch_tb/dut/branch_taken_x sim:/branch_tb/dut/branch_target_x
add wave sim:/branch_tb/dut/forward_rs1_x sim:/branch_tb/dut/forward_rs2_x
run -all
wave zoom full
