onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/cpu5_s05_memory
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/cpu5_memory_work]} {vlib build/cpu5_memory_work}
vmap cpu5_memory_work build/cpu5_memory_work
vlog -sv -work cpu5_memory_work rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/rv32m_unit.v rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/gpio_mmio.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/machine_timer.v rtl/branch_predictor.v rtl/cpu_top.v rtl/soc_instr_mem.v rtl/soc_data_mem.v rtl/dmem_region_router.v rtl/instr_cache.v rtl/data_cache.v tb/cpu5_memory_ii_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/cpu5_s05_memory/memory_ii.wlf cpu5_memory_work.cpu5_memory_ii_tb
run -all
if {[examine -radix unsigned sim:/cpu5_memory_ii_tb/test_pass] != 1} {error "memory II fixture stopped without PASS"}
echo "CPU5 MEMORY II MEASUREMENT VERIFIED"
catch {quit -sim}
quit -code 0 -f
