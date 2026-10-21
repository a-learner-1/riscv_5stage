onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/cpu5_s05_m/cpu_directed
transcript file build/cpu5_s05_m/cpu_directed/modelsim_transcript.log
exec python -B tools/generate_rv32m_vectors.py
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/cpu5_m_cpu_work]} {vlib build/cpu5_m_cpu_work}
vmap cpu5_m_cpu_work build/cpu5_m_cpu_work
vlog -sv +incdir+. -work cpu5_m_cpu_work rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/rv32m_unit.v rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/gpio_mmio.v rtl/machine_timer.v rtl/cpu_top.v tb/rv32m_cpu_tb.v tb/cpu5_m_cpu_timing_tb.v
vsim -voptargs=+acc -onfinish stop -wlf build/cpu5_s05_m/cpu_directed/observation.wlf cpu5_m_cpu_work.cpu5_m_cpu_timing_tb +M_OUTPUT=build/cpu5_s05_m/cpu_directed
log sim:/cpu5_m_cpu_timing_tb/edge_id sim:/cpu5_m_cpu_timing_tb/owner sim:/cpu5_m_cpu_timing_tb/oid sim:/cpu5_m_cpu_timing_tb/cpu/dut/m_start_x sim:/cpu5_m_cpu_timing_tb/cpu/dut/m_complete_x sim:/cpu5_m_cpu_timing_tb/cpu/dut/m_wait_x sim:/cpu5_m_cpu_timing_tb/cpu/dut/m_done
run -all
if {[examine -radix unsigned sim:/cpu5_m_cpu_timing_tb/test_pass] != 1} {error "CPU timing directed test failed"}
catch {quit -sim}
quit -code 0 -f
