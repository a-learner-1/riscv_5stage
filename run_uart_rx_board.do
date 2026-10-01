catch {quit -sim}
if {![file exists programs/uart_rx_echo.hex]} {error "Run build_uart_rx.bat first"}
if {![file exists modelsim.ini]} {vmap -c}
if {![file exists uart_rx_board_work]} {vlib uart_rx_board_work}
vmap uart_rx_board_work uart_rx_board_work
vlog -sv -work uart_rx_board_work \
    rtl/instr_mem.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v \
    rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v \
    rtl/gpio_mmio.v rtl/cpu_top.v rtl/board_reset.v rtl/board_top.v tb/uart_rx_board_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf uart_rx_board_run.wlf uart_rx_board_work.uart_rx_board_tb
add wave sim:/uart_rx_board_tb/clk_50m
add wave sim:/uart_rx_board_tb/key1_n
add wave sim:/uart_rx_board_tb/rx
add wave sim:/uart_rx_board_tb/tx
add wave -radix unsigned sim:/uart_rx_board_tb/received
run -all
if {[examine -radix unsigned sim:/uart_rx_board_tb/test_pass] != 1} {
    error "Board UART RX echo test stopped without PASS"
}
catch {wave zoom full}
