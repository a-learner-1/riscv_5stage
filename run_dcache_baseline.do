# Focused compatibility regression: existing images with D-cache disabled.
onerror {quit -code 1 -f}
catch {quit -sim}
if {![file exists modelsim.ini]} {vmap -c}
if {![file exists dcache_work]} {vlib dcache_work}
vmap dcache_work dcache_work
vlog -sv -work dcache_work {*}[glob rtl/*.v] \
    tb/instr_cache_tb.v tb/icache_board_tb.v tb/timer_irq_board_tb.v tb/trap_c_tb.v \
    tb/axi_control_system_tb.v tb/timer_irq_c_tb.v
foreach top {instr_cache_tb icache_board_tb timer_irq_board_tb trap_c_tb axi_control_system_tb timer_irq_c_tb} {
    catch {quit -sim}
    vsim -voptargs="+acc" -onfinish stop -wlf build/dcache_baseline_${top}.wlf dcache_work.$top
    run -all
    if {[examine -radix unsigned sim:/$top/test_pass] != 1} {error "$top stopped without PASS"}
    echo "D-CACHE DISABLED BASELINE $top test_pass=1"
}
echo "DCACHE DISABLED BASELINE ALL TESTS PASS"
