# Future verification entry. No build, simulation or timing check was run for
# this new code when it was prepared. It never invokes a firmware builder.
onerror {quit -code 1 -f}
catch {quit -sim}
if {![file isdirectory build]} {file mkdir build}
if {![file exists modelsim.ini]} {vmap -c}

# Reject missing, stale or mismatched firmware before compiling any real case.
foreach coremark_axi_configuration {off on on_btb} {
    set coremark_axi_cache [expr {$coremark_axi_configuration eq "off" ? "off" : "on"}]
    set coremark_axi_btb [expr {$coremark_axi_configuration eq "on_btb" ? "on" : "off"}]
    foreach coremark_axi_profile {smoke smoke_validation} {
        set coremark_axi_firmware coremark_axi_cache_${coremark_axi_configuration}_${coremark_axi_profile}
        if {[catch {exec python tools/coremark_axi_contract.py --firmware $coremark_axi_firmware --cache $coremark_axi_cache --btb $coremark_axi_btb --simulation} coremark_axi_guard]} {
            error "AXI CoreMark firmware guard rejected $coremark_axi_firmware: $coremark_axi_guard"
        }
        echo $coremark_axi_guard
    }
}

set coremark_axi_stats_lib coremark_axi_stats_work
if {![file isdirectory $coremark_axi_stats_lib]} {vlib $coremark_axi_stats_lib}
vmap $coremark_axi_stats_lib $coremark_axi_stats_lib
vlog -sv -work $coremark_axi_stats_lib rtl/axi_lite_coremark_stats.v tb/axi_lite_coremark_stats_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/coremark_axi_stats.wlf $coremark_axi_stats_lib.axi_lite_coremark_stats_tb
add wave sim:/axi_lite_coremark_stats_tb/test_pass
add wave sim:/axi_lite_coremark_stats_tb/cache_off/done
add wave sim:/axi_lite_coremark_stats_tb/cache_on/done
add wave sim:/axi_lite_coremark_stats_tb/cache_on_btb/done
run -all
if {[examine -radix unsigned sim:/axi_lite_coremark_stats_tb/test_pass] != 1} {
    error "AXI CoreMark statistics module stopped without PASS"
}
echo "COREMARK AXI STATS test_pass=1"

foreach coremark_axi_configuration {off on on_btb} {
    foreach coremark_axi_profile {smoke smoke_validation} {
        catch {quit -sim}
        set coremark_axi_stem coremark_axi_cache_${coremark_axi_configuration}_${coremark_axi_profile}
        set coremark_axi_lib ${coremark_axi_stem}_work
        if {![file isdirectory $coremark_axi_lib]} {vlib $coremark_axi_lib}
        vmap $coremark_axi_lib $coremark_axi_lib
        set coremark_axi_define +define+COREMARK_CONFIG=\"programs/${coremark_axi_stem}_config.vh\"
        vlog -sv -work $coremark_axi_lib $coremark_axi_define \
            rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v \
            rtl/alu.v rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/gpio_mmio.v \
            rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/machine_timer.v \
            rtl/branch_predictor.v rtl/rv32m_unit.v rtl/cpu_top.v rtl/soc_instr_mem.v rtl/dmem_axi_lite_bridge.v rtl/axi_lite_ram.v \
            rtl/instr_cache.v rtl/data_cache.v rtl/soc_axi_lite_top.v rtl/axi_lite_1x2.v \
            rtl/axi_lite_coremark_stats.v rtl/soc_coremark_axi_top.v tb/coremark_axi_tb.v
        vsim -voptargs="+acc" -onfinish stop -wlf build/${coremark_axi_stem}.wlf $coremark_axi_lib.coremark_axi_tb
        add wave sim:/coremark_axi_tb/test_pass
        foreach coremark_axi_signal {clk rst_n pc_x instr_x cycle_count instret_count completion_seen completed_result snapshots observed_start observed_stop stored_total stored_cycle_delta stored_instret_delta i_hit i_miss d_hit d_miss bp_lookup bp_hit bp_taken bp_resolved bp_next_pc_mismatch bp_direction_error bp_target_error stored_bp} {
            add wave sim:/coremark_axi_tb/$coremark_axi_signal
        }
        foreach coremark_axi_signal {timer_mtime csr_mstatus csr_mie mem_req_fire mem_rsp_fire mem_addr_x mmio_putchar_valid mmio_putchar_data} {
            add wave sim:/coremark_axi_tb/dut/u_core/u_cpu/$coremark_axi_signal
        }
        run -all
        if {[examine -radix unsigned sim:/coremark_axi_tb/test_pass] != 1} {
            error "AXI CoreMark $coremark_axi_stem stopped without PASS"
        }
        echo "COREMARK AXI $coremark_axi_stem test_pass=1"
    }
}
echo "COREMARK AXI SHORT TESTS PASS (three statistics modes and six firmware cases; no formal score)"
catch {wave zoom full}
unset -nocomplain coremark_axi_configuration coremark_axi_cache coremark_axi_btb coremark_axi_profile coremark_axi_firmware \
    coremark_axi_guard coremark_axi_stats_lib coremark_axi_stem coremark_axi_lib \
    coremark_axi_define coremark_axi_signal
