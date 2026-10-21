# Dedicated D0 firmware and native BRAM measurement, with the original workload gates.
onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/verification
if {![file exists modelsim.ini]} {vmap -c}
foreach d0_kind {smoke smoke_validation} {
    set d0_stem coremark_d0_cache_on_btb_${d0_kind}
    if {[catch {exec python -B tools/coremark_axi_contract.py --firmware $d0_stem --cache on --btb on --backend bram --simulation} d0_guard]} {puts stderr $d0_guard;quit -code 1 -f}
    echo $d0_guard
    catch {quit -sim}
    set d0_lib d0_${d0_kind}_work
    if {![file isdirectory build/$d0_lib]} {vlib build/$d0_lib}
    vmap $d0_lib build/$d0_lib
    set d0_define +define+COREMARK_CONFIG=\"programs/${d0_stem}_config.vh\"
    vlog -sv -work $d0_lib $d0_define rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/gpio_mmio.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/machine_timer.v rtl/branch_predictor.v rtl/rv32m_unit.v rtl/cpu_top.v rtl/soc_instr_mem.v rtl/soc_data_mem.v rtl/dmem_region_router.v rtl/dmem_axi_lite_bridge.v rtl/axi_lite_ram.v rtl/instr_cache.v rtl/data_cache.v rtl/soc_axi_lite_top.v rtl/axi_lite_1x2.v rtl/axi_lite_coremark_stats.v rtl/soc_coremark_axi_top.v tb/coremark_d0_workload_tb.v tb/coremark_d0_measure_tb.v
    vsim -voptargs="+acc" -onfinish stop -wlf build/verification/coremark_d0_${d0_kind}.wlf $d0_lib.coremark_d0_measure_tb
    run -all
    if {[examine -radix unsigned sim:/coremark_d0_measure_tb/test_pass] != 1 || [examine -radix unsigned sim:/coremark_d0_measure_tb/workload/test_pass] != 1} {puts stderr "D0 CoreMark stopped without all original and measurement gates";quit -code 1 -f}
    echo "COREMARK D0 $d0_kind test_pass=1"
}
if {[catch {exec python -B tools/analyze_coremark_d0_measure.py --directory build/verification --output build/verification/coremark_d0_analysis.json} d0_analysis]} {puts stderr $d0_analysis;quit -code 1 -f}
echo $d0_analysis
echo "COREMARK D0 ALL TESTS PASS"
catch {quit -sim}
unset -nocomplain d0_kind d0_stem d0_guard d0_lib d0_define d0_analysis
