# RV32IM D0 dual-seed real CoreMark regression; no formal-score claim.
onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/verification
if {![file exists modelsim.ini]} {vmap -c}
foreach m_kind {smoke smoke_validation} {
    set m_stem coremark_d0_m_cache_on_btb_${m_kind}
    if {[catch {exec python -B tools/coremark_axi_contract.py --firmware $m_stem --cache on --btb on --backend bram --isa rv32im --simulation} m_guard]} {error "RV32IM firmware guard rejected $m_stem: $m_guard"}
    echo $m_guard
    catch {quit -sim}
    set m_lib coremark_d0_m_${m_kind}_work
    if {![file isdirectory build/$m_lib]} {vlib build/$m_lib}
    vmap $m_lib build/$m_lib
    set m_define +define+COREMARK_CONFIG=\"programs/${m_stem}_config.vh\"
    vlog -sv -work $m_lib $m_define rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/rv32m_unit.v rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/gpio_mmio.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/machine_timer.v rtl/branch_predictor.v rtl/cpu_top.v rtl/soc_instr_mem.v rtl/soc_data_mem.v rtl/dmem_region_router.v rtl/dmem_axi_lite_bridge.v rtl/axi_lite_ram.v rtl/instr_cache.v rtl/data_cache.v rtl/soc_axi_lite_top.v rtl/axi_lite_1x2.v rtl/axi_lite_coremark_stats.v rtl/soc_coremark_axi_top.v tb/coremark_d0_workload_tb.v
    vsim -voptargs="+acc" -onfinish stop -wlf build/verification/coremark_d0_m_${m_kind}.wlf $m_lib.coremark_d0_workload_tb
    run -all
    if {[examine -radix unsigned sim:/coremark_d0_workload_tb/test_pass] != 1} {error "RV32IM CoreMark $m_kind stopped without original workload checks"}
    echo "COREMARK RV32IM $m_kind test_pass=1"
}
echo "COREMARK RV32IM DUAL SEED PASS (functional smoke; no formal score)"
catch {quit -sim}
unset -nocomplain m_kind m_stem m_guard m_lib m_define
