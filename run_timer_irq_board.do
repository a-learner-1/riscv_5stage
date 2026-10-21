onerror {quit -code 1 -f}
catch {quit -sim}
foreach image {timer_irq_board.hex timer_irq_board_data.hex timer_irq_board_sim_data.hex timer_irq_board_symbols.vh} {
    if {![file exists programs/$image]} {error "Missing programs/$image; run build_timer_irq_board.bat"}
}
# Bind simulation images/symbols to the same current firmware build.
exec python -c {
import hashlib, json, sys
from pathlib import Path
sys.path.insert(0, 'tools')
from build_pds_board import validate_timer_irq_board_firmware
root = Path.cwd()
report_path = validate_timer_irq_board_firmware(root)
report = json.loads(report_path.read_text())
for name in ('programs/timer_irq_board_sim_data.hex', 'programs/timer_irq_board_symbols.vh'):
    assert hashlib.sha256((root/name).read_bytes()).hexdigest() == report['images_sha256'][name], 'Stale timer simulation image/symbols: ' + name
}
if {![file exists modelsim.ini]} {vmap -c}
if {![file exists timer_irq_board_work]} {vlib timer_irq_board_work}
vmap timer_irq_board_work timer_irq_board_work
vlog -sv -work timer_irq_board_work \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v \
    rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v \
    rtl/uart_rx_mmio.v rtl/gpio_mmio.v rtl/machine_timer.v rtl/rv32m_unit.v rtl/cpu_top.v rtl/board_reset.v rtl/soc_instr_mem.v \
    rtl/dmem_axi_lite_bridge.v rtl/axi_lite_ram.v rtl/soc_axi_lite_top.v rtl/timer_irq_board_top.v \
    tb/timer_irq_board_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf timer_irq_board_run.wlf timer_irq_board_work.timer_irq_board_tb
add wave sim:/timer_irq_board_tb/test_pass
add wave -radix hexadecimal sim:/timer_irq_board_tb/done
foreach signal {clk key1_n boots led tx traps mrets work_writes checksum_writes in_isr} {
    add wave sim:/timer_irq_board_tb/normal/$signal
}
foreach signal {cpu_rst_n trap_valid trap_pc trap_cause trap_tval imem_fault dmem_fault} {
    add wave -radix hexadecimal sim:/timer_irq_board_tb/normal/dut/$signal
}
foreach signal {csr_mstatus csr_mie csr_mepc timer_mtip} {
    add wave -radix hexadecimal sim:/timer_irq_board_tb/normal/dut/u_soc/u_cpu/$signal
}
add wave -radix unsigned sim:/timer_irq_board_tb/normal/dut/u_soc/u_cpu/timer_mtime
add wave -radix unsigned sim:/timer_irq_board_tb/normal/dut/u_soc/u_cpu/timer_mtimecmp
add wave sim:/timer_irq_board_tb/reset_handler/key1_n
add wave sim:/timer_irq_board_tb/software_fail/led
run -all
if {[examine -radix unsigned sim:/timer_irq_board_tb/test_pass] != 1} {
    error "Timer IRQ board stopped without PASS"
}
echo "Timer IRQ board test_pass=1"
catch {wave zoom full}
