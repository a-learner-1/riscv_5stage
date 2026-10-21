onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/verification
if {[catch {exec python -B -c {import sys;sys.path.insert(0,'tools');import build_axi_burst_demo_images as b;b.validate_axi_burst_demo_firmware(b.ROOT);print('AXI4 DEMO INPUTS PASS')}} firmware_guard]} {puts stderr $firmware_guard;quit -code 1 -f}
echo $firmware_guard
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/axi4_soc_work]} {vlib build/axi4_soc_work}
vmap axi4_soc_work build/axi4_soc_work
vlog -sv -work axi4_soc_work rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/gpio_mmio.v rtl/machine_timer.v rtl/rv32m_unit.v rtl/cpu_top.v rtl/soc_instr_mem.v rtl/soc_data_mem.v rtl/dmem_region_router.v rtl/dmem_axi_lite_bridge.v rtl/axi_lite_ram.v rtl/instr_cache.v rtl/data_cache.v rtl/soc_axi_lite_top.v rtl/axi_lite_1x2.v rtl/axi_lite_coremark_stats.v rtl/axi_lite_burst_reader.v rtl/axi4_read_1x2.v rtl/axi4_read_ram.v rtl/soc_axi_burst_demo_top.v tb/axi4_read_contract_monitor.v tb/axi4_burst_soc_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/verification/axi4_burst_soc.wlf axi4_soc_work.axi4_burst_soc_tb
run -all
if {[examine -radix unsigned sim:/axi4_burst_soc_tb/test_pass] != 1} {puts stderr "AXI4 SoC stopped without PASS";quit -code 1 -f}
echo "AXI4 BURST SOC test_pass=1"
catch {quit -sim}
