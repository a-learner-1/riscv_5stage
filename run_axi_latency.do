# Focused AXI protocol, response latency and precise-fault verification.
onerror {quit -code 1 -f}
catch {quit -sim}
if {![file isdirectory build]} {file mkdir build}
if {![file exists modelsim.ini]} {vmap -c}
set latency_lib axi_latency_work
if {![file isdirectory $latency_lib]} {vlib $latency_lib}
vmap $latency_lib $latency_lib
vlog -sv -work $latency_lib \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v \
    rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/branch_predictor.v \
    rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/uart_rx.v \
    rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/gpio_mmio.v rtl/machine_timer.v rtl/cpu_top.v \
    rtl/soc_instr_mem.v rtl/dmem_axi_lite_bridge.v rtl/axi_lite_ram.v rtl/axi_lite_1x2.v \
    rtl/instr_cache.v rtl/data_cache.v rtl/soc_axi_lite_top.v \
    rtl/axi_lite_dcache_stats.v rtl/soc_dcache_stats_top.v \
    tb/axi_lite_ram_tb.v tb/axi_lite_1x2_tb.v tb/axi_lite_latency_tb.v \
    tb/axi_lite_bridge_tb.v tb/axi_lite_cpu_tb.v tb/dcache_fault_tb.v tb/dcache_trap_tb.v
foreach latency_top {axi_lite_ram_tb axi_lite_1x2_tb axi_lite_latency_tb axi_lite_bridge_tb axi_lite_cpu_tb dcache_fault_tb dcache_trap_tb} {
    catch {quit -sim}
    vsim -voptargs="+acc" -onfinish stop -wlf build/${latency_top}_latency.wlf $latency_lib.$latency_top
    add wave sim:/$latency_top/test_pass
    run -all
    if {[examine -radix unsigned sim:/$latency_top/test_pass] != 1} {
        error "$latency_top stopped without PASS"
    }
    echo "AXI latency $latency_top test_pass=1"
}
echo "AXI LOW LATENCY ALL TESTS PASS"
unset -nocomplain latency_top latency_lib
