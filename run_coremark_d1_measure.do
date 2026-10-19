# D1 measurement entry: M1 (STORE -> next memory-op spacing) and M2 (BTB
# direction-error split). Observes the real CoreMark AXI workload; never
# builds firmware. A missing/stale image is rejected by the existing guard.
onerror {quit -code 1 -f}
catch {quit -sim}
if {![file isdirectory build]} {file mkdir build}
if {![file exists modelsim.ini]} {vmap -c}

foreach d1_profile {smoke smoke_validation} {
    set d1_stem coremark_axi_cache_on_btb_${d1_profile}
    if {[catch {exec python tools/coremark_axi_contract.py \
            --firmware $d1_stem --cache on --btb on --simulation} d1_guard]} {
        error "D1 firmware guard rejected $d1_stem: $d1_guard"
    }
    echo $d1_guard

    catch {quit -sim}
    set d1_lib d1_${d1_profile}_work
    set d1_lib_path [file join build $d1_lib]
    if {![file isdirectory $d1_lib_path]} {vlib $d1_lib_path}
    vmap $d1_lib $d1_lib_path
    set d1_define +define+COREMARK_CONFIG=\"programs/${d1_stem}_config.vh\"
    vlog -sv -work $d1_lib $d1_define \
        rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v \
        rtl/alu.v rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/gpio_mmio.v \
        rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/machine_timer.v \
        rtl/branch_predictor.v rtl/cpu_top.v rtl/soc_instr_mem.v rtl/dmem_axi_lite_bridge.v \
        rtl/axi_lite_ram.v rtl/instr_cache.v rtl/data_cache.v rtl/soc_axi_lite_top.v \
        rtl/axi_lite_1x2.v rtl/axi_lite_coremark_stats.v rtl/soc_coremark_axi_top.v \
        tb/coremark_axi_tb.v tb/coremark_d1_measure_tb.v
    vsim -voptargs="+acc" -onfinish stop -wlf build/d1_measure_${d1_profile}.wlf \
        $d1_lib.coremark_d1_measure_tb
    add wave sim:/coremark_d1_measure_tb/test_pass
    add wave sim:/coremark_d1_measure_tb/workload/test_pass
    run -all
    # The unchanged workload stops immediately after raising its PASS.
    # Resume only that successful stop for the observer finalizer (#2).
    # This works with the original TB and with its existing optional parameter.
    if {[examine -radix unsigned sim:/coremark_d1_measure_tb/test_pass] != 1 &&
        [examine -radix unsigned sim:/coremark_d1_measure_tb/workload/test_pass] == 1} {
        run 10 ns
    }
    if {[examine -radix unsigned sim:/coremark_d1_measure_tb/test_pass] != 1} {
        error "D1 measure $d1_profile stopped without PASS"
    }
    echo "D1 MEASURE $d1_profile test_pass=1"
}

if {[catch {exec python tools/analyze_d1_measure.py} d1_report]} {
    error "D1 SIM finished, but analyzer is NOT PASS: $d1_report. Run analyzer manually and verify exit code 0."
}
echo $d1_report
echo "D1 ALL PASS (build/d1_measure_*.csv; analyzer verified)"
catch {quit -sim}
unset -nocomplain d1_profile d1_stem d1_guard d1_lib d1_lib_path d1_define d1_report
