onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/cpu5_s16_profile_program
transcript file build/cpu5_s16_profile_program/modelsim_transcript.log
exec python -B tools/run_cpu5_profile_program.py --generate-only
if {![file isdirectory build/cpu5_s16_profile_program/program_work]} {vlib build/cpu5_s16_profile_program/program_work}
vmap cpu5_s16_profile_program_work build/cpu5_s16_profile_program/program_work
vlog -sv +incdir+. -work cpu5_s16_profile_program_work rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v rtl/alu.v rtl/regfile.v rtl/rv32m_unit.v rtl/cpu5_if_adapter.v rtl/cpu5_hazard.v rtl/cpu5_pipeline_skeleton.v rtl/cpu5_alu_decode.v rtl/cpu5_branch_unit.v rtl/cpu5_ram_unit.v rtl/cpu5_ram_owner.v rtl/cpu5_csr_unit.v rtl/cpu5_m_owner.v rtl/cpu5_irq_ctrl.v rtl/cpu5_mmio_endpoint.v rtl/cpu5_mmio_router.v rtl/cpu5_machine_endpoint.v rtl/cpu5_machine_router.v rtl/machine_timer.v rtl/gpio_mmio.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/cpu5_alu_pipeline.v rtl/cpu5_top.v rtl/cpu5_cached_top.v rtl/cpu5_cache_adapter.v rtl/instr_cache.v rtl/data_cache.v rtl/cpu5_d0_axi_lite_top.v rtl/cpu5_d0_backend.v rtl/dmem_region_router.v rtl/soc_data_mem.v rtl/data_bus_adapter.v rtl/dmem_axi_lite_bridge.v rtl/axi_lite_ram.v rtl/axi_lite_cpu5_stats.v rtl/data_mem.v tb/cpu5_profile_program_tb.v
foreach cache_group {0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23} {
    vsim -voptargs="+acc" -onfinish stop -gCACHE_GROUP=$cache_group -wlf build/cpu5_s16_profile_program/program${cache_group}.wlf cpu5_s16_profile_program_work.cpu5_profile_program_tb
    log -r sim:/cpu5_profile_program_tb/*
    run -all
    if {[examine -radix unsigned sim:/cpu5_profile_program_tb/test_pass] != 1} {error "CPU5 AXI program stopped without success"}
    catch {quit -sim}
}
quit -code 0 -f
