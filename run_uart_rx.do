catch {quit -sim}
if {![file exists programs/uart_rx_echo_test.hex] ||
    ![file exists programs/uart_rx_echo_test_data.hex]} {
    error "UART RX test images missing; run build_uart_rx.bat first"
}

if {![file exists modelsim.ini]} {vmap -c}
set uart_rx_lib uart_rx_work
if {![file exists $uart_rx_lib]} {vlib $uart_rx_lib}
vmap $uart_rx_lib $uart_rx_lib
vlog -sv -work $uart_rx_lib \
    rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v \
    rtl/data_mem.v rtl/data_bus_adapter.v rtl/gpio_mmio.v rtl/rv32m_unit.v rtl/cpu_top.v tb/uart_rx_cpu_tb.v

vsim -voptargs="+acc" -onfinish stop -wlf uart_rx_cpu_run.wlf uart_rx_work.uart_rx_cpu_tb
add wave sim:/uart_rx_cpu_tb/clk
add wave sim:/uart_rx_cpu_tb/rst_n
add wave sim:/uart_rx_cpu_tb/rx
add wave sim:/uart_rx_cpu_tb/uart_tx
add wave -radix unsigned sim:/uart_rx_cpu_tb/sent
add wave -radix unsigned sim:/uart_rx_cpu_tb/echoed
add wave -radix unsigned sim:/uart_rx_cpu_tb/rx_data_reads
add wave -radix unsigned sim:/uart_rx_cpu_tb/rx_status_reads
add wave -radix hexadecimal sim:/uart_rx_cpu_tb/last_rx_status
add wave sim:/uart_rx_cpu_tb/dut/load_pending
add wave sim:/uart_rx_cpu_tb/dut/u_uart_rx_mmio/read_enable
add wave -radix unsigned sim:/uart_rx_cpu_tb/dut/u_data_mem/mem(4095)
run -all
if {[examine -radix unsigned sim:/uart_rx_cpu_tb/test_pass] != 1} {
    error "CPU UART RX echo test stopped without PASS"
}
catch {wave zoom full}
