# Run from the repository root. This script runs one finite CPU GPIO test.
catch {quit -sim}
if {![file exists programs/gpio_test.hex] || ![file exists programs/gpio_test_data.hex]} {
    error "GPIO images missing; run build_gpio.bat first"
}
if {![file exists modelsim.ini]} {vmap -c}
set gpio_lib gpio_work
if {![file exists $gpio_lib]} {vlib $gpio_lib}
vmap $gpio_lib $gpio_lib
vlog -sv -work $gpio_lib \
    rtl/instr_mem.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v \
    rtl/alu.v rtl/data_mem.v rtl/uart_tx.v rtl/gpio_mmio.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/cpu_top.v tb/gpio_cpu_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf gpio_cpu_run.wlf gpio_work.gpio_cpu_tb
add wave sim:/gpio_cpu_tb/clk
add wave sim:/gpio_cpu_tb/rst_n
add wave -radix hexadecimal sim:/gpio_cpu_tb/gpio_in
add wave -radix hexadecimal sim:/gpio_cpu_tb/gpio_out
add wave -radix hexadecimal sim:/gpio_cpu_tb/gpio_oe
add wave -radix hexadecimal sim:/gpio_cpu_tb/pc_x
add wave sim:/gpio_cpu_tb/dut/mmio_gpio_write_x
add wave -radix hexadecimal sim:/gpio_cpu_tb/dut/mem_addr_x
add wave -radix hexadecimal sim:/gpio_cpu_tb/dut/mmio_read_data_x
add wave -radix unsigned sim:/gpio_cpu_tb/gpio_writes
add wave -radix unsigned sim:/gpio_cpu_tb/gpio_reads
add wave -radix unsigned sim:/gpio_cpu_tb/dut/u_data_mem/mem(4095)
run -all
catch {wave zoom full}
