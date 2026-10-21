onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/verification
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/btb_rom_cpu_work]} {vlib build/btb_rom_cpu_work}
vmap btb_rom_cpu_work build/btb_rom_cpu_work
vlog -sv -work btb_rom_cpu_work rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/gpio_mmio.v rtl/machine_timer.v rtl/rv32m_unit.v rtl/cpu_top.v tb/btb_rom_boundary_cpu_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/verification/btb_rom_boundary_cpu.wlf btb_rom_cpu_work.btb_rom_boundary_cpu_tb
run -all
if {[examine -radix unsigned sim:/btb_rom_boundary_cpu_tb/test_pass] != 1} {puts stderr "BTB ROM boundary CPU stopped without PASS";quit -code 1 -f}
echo "BTB ROM BOUNDARY CPU test_pass=1"
catch {quit -sim}
