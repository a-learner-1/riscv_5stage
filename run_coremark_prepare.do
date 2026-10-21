# Only the newly prepared CoreMark paths; no historical regression reruns.
onerror {quit -code 1 -f}
if {![info exists coremark_prepare_start]} {set coremark_prepare_start 0}
if {![info exists coremark_prepare_math]} {set coremark_prepare_math 1}
if {$coremark_prepare_start < 0 || $coremark_prepare_start > 3} {error "coremark_prepare_start must be 0..3 (3 resumes board startup and port math)"}
if {$coremark_prepare_math ni {0 1}} {error "coremark_prepare_math must be 0 or 1"}
set coremark_prepare_complete [expr {$coremark_prepare_start == 0 && $coremark_prepare_math == 1}]
foreach coremark_profile [lrange {smoke smoke_validation formal_short} $coremark_prepare_start end] {
    echo "COREMARK PREPARE BEGIN $coremark_profile"
    do run_coremark.do
    echo "COREMARK PREPARE END $coremark_profile"
}
unset -nocomplain coremark_profile
catch {quit -sim}
foreach image {coremark_performance.hex coremark_performance_data.hex} {
    if {![file exists programs/$image]} {error "Missing $image; build performance profile first"}
}
if {![file isdirectory coremark_board_work]} {vlib coremark_board_work}
vmap coremark_board_work coremark_board_work
vlog -sv -work coremark_board_work \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v \
    rtl/alu.v rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/gpio_mmio.v \
    rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/machine_timer.v \
    rtl/rv32m_unit.v rtl/cpu_top.v rtl/board_reset.v rtl/coremark_board_top.v tb/coremark_prepare_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/coremark_board_startup.wlf coremark_board_work.coremark_prepare_tb
add wave sim:/coremark_prepare_tb/test_pass
foreach signal {clk key1_n led tx} {add wave sim:/coremark_prepare_tb/$signal}
foreach signal {cpu_rst_n u_cpu/timer_mtime u_cpu/cycle_count u_cpu/counting_started u_cpu/csr_mstatus u_cpu/csr_mie} {
    add wave sim:/coremark_prepare_tb/dut/$signal
}
run -all
if {[examine -radix unsigned sim:/coremark_prepare_tb/test_pass] != 1} {error "CoreMark board startup stopped without PASS"}
echo "CoreMark board startup test_pass=1"
catch {wave zoom full}
if {$coremark_prepare_math} {
    if {![file exists run_coremark_port_math.do]} {error "Missing run_coremark_port_math.do"}
    do run_coremark_port_math.do
}
if {$coremark_prepare_complete} {
    echo "COREMARK PREPARE ALL TESTS PASS (short tests only; no formal score)"
} else {
    echo "COREMARK PREPARE SELECTED TESTS PASS (partial verification; short tests only; no formal score)"
}
unset coremark_prepare_start coremark_prepare_math coremark_prepare_complete
