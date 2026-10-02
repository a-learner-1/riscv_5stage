# Run only after a CPU/integration change. Do not repeat to view old waves.
# Excludes unchanged peripheral, RAM and AXI unit tests and old CoreMark.
onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory timer_affected_work]} {vlib timer_affected_work}
vmap timer_affected_work timer_affected_work
set timer_affected_cases {cpu_top_tb branch_tb compare_branch_tb jump_tb load_store_tb subword_mem_tb
    mmio_tb gpio_cpu_tb uart_cpu_tb uart_rx_cpu_tb c_program_tb performance_tb
    program_load_tb toolchain_program_tb data_handshake_tb fetch_handshake_tb
    soc_top_tb soc_fault_tb axi_lite_cpu_tb axi_control_system_tb axi_control_board_tb
    cpu_trap_tb cpu_trap_edges_tb trap_c_tb trap_board_tb}
set timer_affected_sources [glob rtl/*.v]
foreach testcase $timer_affected_cases {lappend timer_affected_sources tb/$testcase.v}
vlog -quiet -sv -work timer_affected_work {*}$timer_affected_sources
set timer_affected_checked 0
if {![info exists timer_affected_start]} {set timer_affected_start 0}
foreach testcase [lrange $timer_affected_cases $timer_affected_start end] {
    echo "TIMER AFFECTED BEGIN $testcase"
    vsim -quiet -voptargs="+acc" -onfinish stop -wlf build/timer_affected_$testcase.wlf timer_affected_work.$testcase
    run -all
    if {[lsearch -exact {uart_rx_cpu_tb data_handshake_tb fetch_handshake_tb soc_top_tb
                        soc_fault_tb axi_lite_cpu_tb axi_control_system_tb axi_control_board_tb
                        cpu_trap_tb cpu_trap_edges_tb trap_c_tb trap_board_tb} $testcase] >= 0} {
        if {[examine -radix unsigned sim:/$testcase/test_pass] != 1} {
            error "Affected $testcase stopped without PASS"
        }
    }
    echo "TIMER AFFECTED END $testcase"
    incr timer_affected_checked
    quit -sim
}
echo "PASS: timer CPU-change affected integration groups=$timer_affected_checked"
