onerror {quit -code 1 -f}
transcript file compile_transcript.log
vmap -c
vlib work
vmap cpu5_coremark_work work
vlog -sv +incdir+. -work cpu5_coremark_work rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v rtl/alu.v rtl/regfile.v rtl/rv32m_unit.v rtl/cpu5_if_adapter.v rtl/cpu5_hazard.v rtl/cpu5_pipeline_skeleton.v rtl/cpu5_alu_decode.v rtl/cpu5_branch_unit.v rtl/cpu5_ram_unit.v rtl/cpu5_ram_owner.v rtl/cpu5_csr_unit.v rtl/cpu5_m_owner.v rtl/cpu5_irq_ctrl.v rtl/cpu5_alu_pipeline.v rtl/cpu5_top.v rtl/cpu5_cached_top.v rtl/cpu5_cache_adapter.v rtl/instr_cache.v rtl/data_cache.v rtl/cpu5_d0_axi_lite_top.v rtl/cpu5_d0_backend.v rtl/dmem_region_router.v rtl/soc_data_mem.v rtl/data_bus_adapter.v rtl/dmem_axi_lite_bridge.v rtl/axi_lite_ram.v rtl/data_mem.v rtl/cpu5_mmio_endpoint.v rtl/cpu5_mmio_router.v rtl/cpu5_machine_endpoint.v rtl/cpu5_machine_router.v rtl/machine_timer.v rtl/gpio_mmio.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/soc_instr_mem.v rtl/axi_lite_1x2.v rtl/axi_lite_cpu5_stats.v rtl/cpu5_stats_axi_lite_top.v tb/cpu5_coremark_tb.v
echo "CPU5 COREMARK CLEAN COMPILE PASS"
quit -code 0 -f
