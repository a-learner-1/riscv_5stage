# Independent passive baseline observation. Original workload must still pass.
onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/cpu5_stage0_measure
transcript file build/cpu5_stage0_measure/modelsim_transcript.log
if {![file exists modelsim.ini]} {vmap -c}
foreach raw_kind {smoke smoke_validation} {
    set raw_stem coremark_d0_m_cache_on_btb_${raw_kind}
    if {[catch {exec python -B tools/coremark_axi_contract.py --firmware $raw_stem --cache on --btb on --backend bram --isa rv32im --simulation} raw_guard]} {error "Strict firmware guard rejected $raw_stem: $raw_guard"}
    echo $raw_guard
    catch {quit -sim}
    set raw_lib cpu5_baseline_raw_${raw_kind}_work
    set raw_out build/cpu5_stage0_measure/$raw_kind
    file mkdir $raw_out
    if {![file isdirectory build/$raw_lib]} {vlib build/$raw_lib}
    vmap $raw_lib build/$raw_lib
    set raw_define +define+COREMARK_CONFIG=\"programs/${raw_stem}_config.vh\"
    vlog -sv -work $raw_lib $raw_define rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/rv32m_unit.v rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/gpio_mmio.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/machine_timer.v rtl/branch_predictor.v rtl/cpu_top.v rtl/soc_instr_mem.v rtl/soc_data_mem.v rtl/dmem_region_router.v rtl/dmem_axi_lite_bridge.v rtl/axi_lite_ram.v rtl/instr_cache.v rtl/data_cache.v rtl/soc_axi_lite_top.v rtl/axi_lite_1x2.v rtl/axi_lite_coremark_stats.v rtl/soc_coremark_axi_top.v tb/coremark_d0_workload_tb.v tb/cpu5_baseline_raw_tb.v
    vsim -voptargs="+acc" -onfinish stop -wlf $raw_out/observation.wlf $raw_lib.cpu5_baseline_raw_tb +RAW_OUTPUT=$raw_out
    log sim:/cpu5_baseline_raw_tb/clk sim:/cpu5_baseline_raw_tb/rst_n sim:/cpu5_baseline_raw_tb/edge_id sim:/cpu5_baseline_raw_tb/seq_id sim:/cpu5_baseline_raw_tb/live sim:/cpu5_baseline_raw_tb/start_edge sim:/cpu5_baseline_raw_tb/stop_edge sim:/cpu5_baseline_raw_tb/prev_complete sim:/cpu5_baseline_raw_tb/prev_resolve sim:/cpu5_baseline_raw_tb/prev_redirect sim:/cpu5_baseline_raw_tb/workload/wb_pc sim:/cpu5_baseline_raw_tb/workload/retire_valid sim:/cpu5_baseline_raw_tb/workload/instret_count sim:/cpu5_baseline_raw_tb/workload/dut/u_core/u_cpu/pc_x sim:/cpu5_baseline_raw_tb/workload/dut/u_core/u_cpu/bp_resolve_valid sim:/cpu5_baseline_raw_tb/workload/dut/u_core/u_cpu/normal_redirect_x
    run -all
    if {[examine -radix unsigned sim:/cpu5_baseline_raw_tb/test_pass] != 1 || [examine -radix unsigned sim:/cpu5_baseline_raw_tb/workload/test_pass] != 1} {error "RAW observer stopped without both success gates"}
    echo "CPU5 BASELINE RAW $raw_kind ORIGINAL WORKLOAD + OBSERVER PASS"
}
echo "CPU5 BASELINE RAW DUAL SEED PASS (one iteration; no CPU5 stall/Fmax claim)"
catch {quit -sim}
quit -code 0 -f
