catch {quit -sim}
if {![file exists modelsim.ini]} {vmap -c}
set uart_rx_lib uart_rx_unit_work
if {![file exists $uart_rx_lib]} {vlib $uart_rx_lib}
vmap $uart_rx_lib $uart_rx_lib
vlog -sv -work $uart_rx_lib \
    rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v \
    tb/uart_rx_tb.v tb/uart_rx_fifo_tb.v tb/uart_rx_mmio_tb.v

vsim -voptargs="+acc" -onfinish stop -wlf uart_rx_run.wlf uart_rx_unit_work.uart_rx_tb
add wave sim:/uart_rx_tb/*
run -all
if {[examine -radix unsigned sim:/uart_rx_tb/test_pass] != 1} {
    error "UART RX test stopped without PASS"
}
catch {wave zoom full}
quit -sim

vsim -voptargs="+acc" -onfinish stop -wlf uart_rx_fifo_run.wlf uart_rx_unit_work.uart_rx_fifo_tb
add wave sim:/uart_rx_fifo_tb/case16/*
add wave sim:/uart_rx_fifo_tb/case3/*
add wave sim:/uart_rx_fifo_tb/case1/*
run -all
if {[examine -radix unsigned sim:/uart_rx_fifo_tb/test_pass] != 1} {
    error "UART RX FIFO test stopped without PASS"
}
catch {wave zoom full}
quit -sim

vsim -voptargs="+acc" -onfinish stop -wlf uart_rx_mmio_run.wlf uart_rx_unit_work.uart_rx_mmio_tb
add wave sim:/uart_rx_mmio_tb/*
run -all
if {[examine -radix unsigned sim:/uart_rx_mmio_tb/test_pass] != 1} {
    error "UART RX MMIO test stopped without PASS"
}
catch {wave zoom full}
