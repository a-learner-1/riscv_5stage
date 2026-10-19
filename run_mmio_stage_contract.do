# Legal/illegal local-MMIO semantics plus the reset gap in the new input stage.
onerror {quit -code 1 -f}
catch {quit -sim}
if {![info exists mmio_expected_stage]} {set mmio_expected_stage 1}
file mkdir build/verification
if {![file exists modelsim.ini]} {vmap -c}
set mmio_contract_lib mmio_stage_contract_work
if {![file isdirectory build/$mmio_contract_lib]} {vlib build/$mmio_contract_lib}
vmap $mmio_contract_lib build/$mmio_contract_lib
vlog -sv -work $mmio_contract_lib rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/gpio_mmio.v rtl/machine_timer.v rtl/cpu_top.v tb/mmio_stage_contract_tb.v
vsim -voptargs="+acc" -onfinish stop -gEXPECT_MMIO_STAGE=$mmio_expected_stage -wlf build/verification/mmio_stage_contract.wlf $mmio_contract_lib.mmio_stage_contract_tb
run -all
if {[examine -radix unsigned sim:/mmio_stage_contract_tb/test_pass] != 1} {puts stderr "MMIO stage contract stopped without PASS"; quit -code 1 -f}
echo "MMIO STAGE CONTRACT test_pass=1"
catch {quit -sim}
unset -nocomplain mmio_contract_lib mmio_expected_stage
