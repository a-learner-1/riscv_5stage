# Future image-level simulation. This script does not build firmware.
onerror {quit -code 1 -f}
catch {quit -sim}
exec python -c {
import sys
sys.path.insert(0, 'tools')
from build_pds_board import validate_btb_board_firmware
validate_btb_board_firmware()
}
if {![file exists modelsim.ini]} {vmap -c}
set btb_board_lib btb_board_work
if {![file exists $btb_board_lib]} {vlib $btb_board_lib}
vmap $btb_board_lib $btb_board_lib
vlog -sv -work $btb_board_lib \
    rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v \
    rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v rtl/data_bus_adapter.v \
    rtl/gpio_mmio.v rtl/machine_timer.v rtl/cpu_top.v \
    rtl/board_reset.v rtl/btb_board_top.v tb/btb_board_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf btb_board_run.wlf $btb_board_lib.btb_board_tb
add wave sim:/btb_board_tb/done sim:/btb_board_tb/test_pass
add wave sim:/btb_board_tb/normal_restart/clk
add wave sim:/btb_board_tb/normal_restart/key1_n
add wave sim:/btb_board_tb/normal_restart/tx
add wave -radix hexadecimal sim:/btb_board_tb/normal_restart/led
add wave -radix hexadecimal sim:/btb_board_tb/normal_restart/dut/u_cpu/pc_x
add wave -radix hexadecimal sim:/btb_board_tb/normal_restart/dut/u_cpu/predicted_next_pc_x
add wave sim:/btb_board_tb/normal_restart/dut/u_cpu/redirect_x
add wave -radix unsigned sim:/btb_board_tb/normal_restart/dut/u_cpu/bp_hit_count
add wave -radix unsigned sim:/btb_board_tb/normal_restart/dut/u_cpu/bp_mispredict_count
run -all
if {[examine -radix unsigned sim:/btb_board_tb/test_pass] != 1} {
    error "BTB board simulation stopped without PASS"
}
catch {wave zoom full}
