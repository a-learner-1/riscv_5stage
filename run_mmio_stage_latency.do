# Independent data-path latency fingerprint. Run from an isolated project cwd.
onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/verification
if {![file exists modelsim.ini]} {vmap -c}
set mmio_latency_lib mmio_stage_latency_work
if {![file isdirectory build/$mmio_latency_lib]} {vlib build/$mmio_latency_lib}
vmap $mmio_latency_lib build/$mmio_latency_lib
vlog -sv -work $mmio_latency_lib rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/gpio_mmio.v rtl/machine_timer.v rtl/cpu_top.v rtl/data_cache.v tb/mmio_stage_latency_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/verification/mmio_stage_latency.wlf $mmio_latency_lib.mmio_stage_latency_tb
run -all
if {[examine -radix unsigned sim:/mmio_stage_latency_tb/test_pass] != 1} {puts stderr "MMIO stage latency fixture stopped without PASS"; quit -code 1 -f}
echo "MMIO STAGE LATENCY test_pass=1"
catch {quit -sim}
unset -nocomplain mmio_latency_lib
