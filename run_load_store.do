catch {quit -sim}
if {![file exists work]} {vlib work}
vmap work work
vlog -sv -work work rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/gpio_mmio.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/rv32m_unit.v rtl/cpu_top.v tb/load_store_tb.v tb/data_mem_tb.v tb/load_store_decoder_tb.v
vsim -voptargs=+acc -onfinish stop -wlf cpu_load_store_run.wlf work.load_store_tb
add wave sim:/load_store_tb/clk sim:/load_store_tb/rst_n
add wave sim:/load_store_tb/pc_x sim:/load_store_tb/instr_x sim:/load_store_tb/valid_x
add wave sim:/load_store_tb/wb_pc sim:/load_store_tb/wb_rd sim:/load_store_tb/wb_data sim:/load_store_tb/wb_we
add wave sim:/load_store_tb/dut/is_lw_x sim:/load_store_tb/dut/is_sw_x
add wave sim:/load_store_tb/dut/imm_x sim:/load_store_tb/dut/imm_s_x
add wave sim:/load_store_tb/dut/mem_addr_x sim:/load_store_tb/dut/mem_wdata_x sim:/load_store_tb/dut/mem_rdata_x
add wave sim:/load_store_tb/dut/mem_we_x sim:/load_store_tb/dut/mem_re_x
add wave sim:/load_store_tb/dut/forward_rs1_x sim:/load_store_tb/dut/forward_rs2_x
run -all
wave zoom full
