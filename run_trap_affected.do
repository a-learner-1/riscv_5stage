# Use ONLY after changing CPU/decoder/frontend or their integration.
# This list intentionally excludes unchanged peripheral/memory/AXI unit tests
# and the historical CoreMark benchmark. Do not run it merely to view waves.
onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory trap_affected_work]} {vlib trap_affected_work}
vmap trap_affected_work trap_affected_work
set cases {cpu_top_tb branch_tb compare_branch_tb jump_tb load_store_tb subword_mem_tb
    mmio_tb gpio_cpu_tb uart_cpu_tb uart_rx_cpu_tb c_program_tb performance_tb
    program_load_tb toolchain_program_tb data_handshake_tb fetch_handshake_tb
    soc_top_tb soc_fault_tb axi_lite_cpu_tb axi_control_system_tb axi_control_board_tb}
set sources [glob rtl/*.v]
foreach testcase $cases {lappend sources tb/$testcase.v}
vlog -quiet -sv -work trap_affected_work {*}$sources
set checked 0
if {![info exists affected_start]} {set affected_start 0}
foreach testcase [lrange $cases $affected_start end] {
    echo "AFFECTED BEGIN $testcase"
    vsim -quiet -voptargs="+acc" -onfinish stop -wlf build/trap_affected_$testcase.wlf trap_affected_work.$testcase
    run -all
    if {[lsearch -exact {uart_rx_cpu_tb data_handshake_tb fetch_handshake_tb soc_top_tb
                        soc_fault_tb axi_lite_cpu_tb axi_control_system_tb axi_control_board_tb} $testcase] >= 0} {
        if {[examine -radix unsigned sim:/$testcase/test_pass] != 1} {
            error "Affected $testcase stopped without PASS"
        }
    }
    echo "AFFECTED END $testcase"
    incr checked
    quit -sim
}
echo "PASS: CPU-change affected integration groups=$checked"
