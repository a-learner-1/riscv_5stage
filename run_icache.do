onerror {quit -code 1 -f}
catch {quit -sim}
exec python -c {
import sys
sys.path.insert(0,'tools')
from build_pds_board import validate_icache_board_firmware
validate_icache_board_firmware()
}
if {![file exists modelsim.ini]} {vmap -c}
if {![file exists icache_work]} {vlib icache_work}
vmap icache_work icache_work
vlog -sv -work icache_work \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v \
    rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v \
    rtl/uart_rx_mmio.v rtl/gpio_mmio.v rtl/machine_timer.v rtl/cpu_top.v rtl/board_reset.v \
    rtl/soc_instr_mem.v rtl/dmem_axi_lite_bridge.v rtl/axi_lite_ram.v rtl/axi_lite_1x2.v \
    rtl/instr_cache.v rtl/axi_lite_icache_stats.v rtl/soc_axi_lite_top.v \
    rtl/soc_icache_stats_top.v rtl/icache_board_top.v \
    tb/instr_cache_tb.v tb/axi_lite_icache_stats_tb.v tb/icache_frontend_tb.v tb/icache_board_tb.v
foreach top {instr_cache_tb axi_lite_icache_stats_tb icache_frontend_tb icache_board_tb} {
    catch {quit -sim}
    vsim -voptargs="+acc" -onfinish stop -wlf icache_${top}.wlf icache_work.$top
    add wave sim:/$top/test_pass
    if {$top == "icache_board_tb"} {
        add wave -radix hexadecimal sim:/icache_board_tb/done
        foreach signal {clk key1_n led tx traps mrets} {add wave sim:/icache_board_tb/normal/$signal}
        foreach signal {icache_access_count icache_hit_count icache_miss_count icache_refill_word_count icache_error_count} {
            add wave -radix unsigned sim:/icache_board_tb/normal/dut/$signal
        }
    }
    run -all
    if {[examine -radix unsigned sim:/$top/test_pass] != 1} {error "$top stopped without PASS"}
    echo "$top test_pass=1"
}
echo "ICACHE ALL TESTS PASS"
catch {wave zoom full}
