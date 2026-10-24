onerror {quit -code 1 -f}
file mkdir build/cpu5_s11_machine_router
transcript file build/cpu5_s11_machine_router/transcript.log
vmap -c
vlib work
vmap cpu5_s11_router_work work
vlog -sv -work cpu5_s11_router_work rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/gpio_mmio.v rtl/cpu5_mmio_endpoint.v rtl/cpu5_mmio_router.v rtl/machine_timer.v rtl/cpu5_machine_endpoint.v rtl/cpu5_machine_router.v tb/cpu5_machine_router_tb.v
echo "CPU5 MACHINE ROUTER CLEAN COMPILE PASS"
vsim -voptargs="+acc" -onfinish stop -wlf build/cpu5_s11_machine_router/router.wlf cpu5_s11_router_work.cpu5_machine_router_tb
log -r sim:/*
run -all
if {[examine -radix unsigned sim:/cpu5_machine_router_tb/test_pass] != 1} {quit -code 1 -f}
echo "CPU5 MACHINE ROUTER REFERENCE PASS"
quit -code 0 -f
