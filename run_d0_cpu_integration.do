onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/verification
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/d0_cpu_work]} {vlib build/d0_cpu_work}
vmap d0_cpu_work build/d0_cpu_work
vlog -sv -work d0_cpu_work rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/gpio_mmio.v rtl/machine_timer.v rtl/rv32m_unit.v rtl/cpu_top.v rtl/soc_instr_mem.v rtl/soc_data_mem.v rtl/dmem_region_router.v rtl/instr_cache.v rtl/data_cache.v rtl/dmem_axi_lite_bridge.v rtl/soc_axi_lite_top.v rtl/axi_lite_ram.v tb/d0_cpu_integration_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/verification/d0_cpu_integration.wlf d0_cpu_work.d0_cpu_integration_tb
run -all
if {[examine -radix unsigned sim:/d0_cpu_integration_tb/test_pass] != 1} {puts stderr "D0 CPU integration stopped without PASS";quit -code 1 -f}
echo "D0 CPU INTEGRATION test_pass=1"
catch {quit -sim}
