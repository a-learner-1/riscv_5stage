onerror {quit -code 1 -f}
catch {quit -sim}
exec python -c {
import sys
sys.path.insert(0,'tools')
from build_pds_board import validate_dcache_board_firmware
validate_dcache_board_firmware()
}
if {![file exists modelsim.ini]} {vmap -c}
if {![file exists dcache_work]} {vlib dcache_work}
vmap dcache_work dcache_work
vlog -sv -work dcache_work \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v \
    rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v \
    rtl/uart_rx_mmio.v rtl/gpio_mmio.v rtl/machine_timer.v rtl/rv32m_unit.v rtl/cpu_top.v rtl/board_reset.v \
    rtl/soc_instr_mem.v rtl/dmem_axi_lite_bridge.v rtl/axi_lite_ram.v rtl/axi_lite_1x2.v \
    rtl/instr_cache.v rtl/data_cache.v rtl/axi_lite_dcache_stats.v rtl/soc_axi_lite_top.v \
    rtl/soc_dcache_stats_top.v rtl/dcache_board_top.v \
    tb/data_cache_tb.v tb/axi_lite_dcache_stats_tb.v tb/dcache_fault_tb.v tb/dcache_trap_tb.v tb/dcache_board_tb.v
foreach top {data_cache_tb axi_lite_dcache_stats_tb dcache_fault_tb dcache_trap_tb dcache_board_tb} {
    catch {quit -sim}
    vsim -voptargs="+acc" -onfinish stop -wlf build/dcache_${top}.wlf dcache_work.$top
    add wave sim:/$top/test_pass
    if {$top == "dcache_board_tb"} {
        add wave -radix hexadecimal sim:/dcache_board_tb/done
        foreach signal {clk key1_n led tx traps mrets} {add wave sim:/dcache_board_tb/normal/$signal}
        foreach signal {dcache_access_count dcache_hit_count dcache_miss_count dcache_refill_word_count dcache_error_count dcache_write_count dcache_bypass_count} {
            add wave -radix unsigned sim:/dcache_board_tb/normal/dut/u_soc/$signal
        }
    }
    run -all
    if {[examine -radix unsigned sim:/$top/test_pass] != 1} {error "$top stopped without PASS"}
    echo "$top test_pass=1"
}
echo "DCACHE ALL TESTS PASS"
catch {wave zoom full}
