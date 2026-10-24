onerror {quit -code 1 -f}
file mkdir build/cpu5_s10_mmio_router
transcript file build/cpu5_s10_mmio_router/transcript.log
vmap -c
vlib work
vmap cpu5_s10_router_work work
vlog -sv -work cpu5_s10_router_work rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/gpio_mmio.v rtl/cpu5_mmio_endpoint.v rtl/cpu5_mmio_router.v tb/cpu5_mmio_router_tb.v
echo "CPU5 MMIO ROUTER CLEAN COMPILE PASS"
vsim -voptargs="+acc" -onfinish stop -wlf build/cpu5_s10_mmio_router/router.wlf cpu5_s10_router_work.cpu5_mmio_router_tb
log -r sim:/*
run -all
if {[examine -radix unsigned sim:/cpu5_mmio_router_tb/test_pass] != 1} {quit -code 1 -f}
echo "CPU5 MMIO ROUTER REFERENCE PASS"
quit -code 0 -f
