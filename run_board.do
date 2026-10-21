# One finite board-wrapper integration test. Run from the repository root.
catch {quit -sim}
if {![file exists programs/board_demo.hex] || ![file exists programs/board_demo_sim_data.hex]} {
    error "Board firmware missing; run build_board.bat"
}
if {![file exists modelsim.ini]} {vmap -c}
if {![file exists board_work]} {vlib board_work}
vmap board_work board_work
vlog -sv -work board_work \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v \
    rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/gpio_mmio.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/rv32m_unit.v rtl/cpu_top.v \
    rtl/board_reset.v rtl/board_top.v tb/board_top_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf board_run.wlf board_work.board_top_tb
add wave sim:/board_top_tb/clk_50m
add wave sim:/board_top_tb/key1_n
add wave -radix binary sim:/board_top_tb/keys_n
add wave sim:/board_top_tb/dut/cpu_rst_n
add wave -radix hexadecimal sim:/board_top_tb/led
add wave sim:/board_top_tb/uart_tx
add wave -radix unsigned sim:/board_top_tb/boots
add wave -radix hexadecimal sim:/board_top_tb/dut/u_cpu/pc_x
run -all
catch {wave zoom full}
