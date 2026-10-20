onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/verification
if {![file exists modelsim.ini]} {vmap -c}
set lib d0_causal_work
if {![file isdirectory build/$lib]} {vlib build/$lib}
vmap $lib build/$lib
vlog -sv -work $lib rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v rtl/data_bus_adapter.v rtl/gpio_mmio.v rtl/machine_timer.v rtl/cpu_top.v rtl/instr_cache.v rtl/data_cache.v rtl/soc_instr_mem.v rtl/soc_data_mem.v rtl/dmem_axi_lite_bridge.v rtl/dmem_region_router.v rtl/soc_axi_lite_top.v rtl/axi_lite_1x2.v rtl/axi_lite_ram.v rtl/axi_lite_coremark_stats.v rtl/soc_coremark_axi_top.v tb/d0_causal_latency_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/verification/d0_causal_latency.wlf $lib.d0_causal_latency_tb
run -all
if {[examine -radix unsigned sim:/d0_causal_latency_tb/test_pass] != 1} {error "D0 causal latency stopped without PASS"}
echo "D0 CAUSAL LATENCY test_pass=1"
catch {quit -sim}
unset -nocomplain lib
