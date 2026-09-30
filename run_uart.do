catch {quit -sim}
if {![file exists programs/uart_demo.hex] ||
    ![file exists programs/uart_demo_data.hex]} {
    error "UART images missing; run build_uart.bat first"
}

# Use a separate library so other ModelSim windows cannot lock work.
if {![file exists modelsim.ini]} {vmap -c}
set uart_lib uart_work
if {![file exists $uart_lib]} {vlib $uart_lib}
vmap $uart_lib $uart_lib
vlog -sv -work $uart_lib \
    rtl/uart_tx.v rtl/instr_mem.v rtl/if_stage.v rtl/regfile.v \
    rtl/decoder.v rtl/alu.v rtl/data_mem.v rtl/cpu_top.v tb/uart_cpu_tb.v

vsim -voptargs="+acc" -onfinish stop -wlf uart_cpu_run.wlf uart_work.uart_cpu_tb
add wave sim:/uart_cpu_tb/clk
add wave sim:/uart_cpu_tb/rst_n
add wave sim:/uart_cpu_tb/uart_tx
add wave sim:/uart_cpu_tb/dut/uart_busy
add wave sim:/uart_cpu_tb/dut/mmio_putchar_valid
add wave -radix ascii sim:/uart_cpu_tb/dut/mmio_putchar_data
add wave -radix unsigned sim:/uart_cpu_tb/received
add wave -radix unsigned sim:/uart_cpu_tb/busy_reads
add wave -radix unsigned sim:/uart_cpu_tb/dut/u_data_mem/mem(4095)
run -all
catch {wave zoom full}
