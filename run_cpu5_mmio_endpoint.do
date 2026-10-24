onerror {quit -code 1 -f}
# Invoke from the repository root, as with the other run_cpu5_*.do entries.
# ModelSim's do is not Tcl source: info script names an internal installation file.
set root [pwd]
set private_dir [file join $root build cpu5_s10_mmio_endpoint manual]
file mkdir $private_dir
cd $private_dir
file mkdir build/cpu5_s10_mmio_endpoint
transcript file transcript.log
vmap -c
vlib work
vmap cpu5_s10_endpoint work
vlog -sv -work cpu5_s10_endpoint $root/rtl/uart_tx.v $root/rtl/uart_rx.v $root/rtl/uart_rx_fifo.v $root/rtl/uart_rx_mmio.v $root/rtl/gpio_mmio.v $root/rtl/cpu5_mmio_endpoint.v $root/tb/cpu5_mmio_endpoint_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf endpoint.wlf cpu5_s10_endpoint.cpu5_mmio_endpoint_tb
log -r sim:/*
run -all
if {[examine -radix unsigned sim:/cpu5_mmio_endpoint_tb/test_pass] != 1} {quit -code 1 -f}
echo "CPU5 MMIO ENDPOINT REFERENCE PASS"
quit -code 0 -f
