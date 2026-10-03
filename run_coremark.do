# Real C short performance-seed test. Build metadata selects matching images.
onerror {quit -code 1 -f}
catch {quit -sim}
if {![info exists coremark_profile]} {set coremark_profile smoke}
if {$coremark_profile ni {smoke smoke_validation formal_short}} {
    error "HDL permits only smoke, smoke_validation or formal_short; formal auto-calibration is for the board"
}
set coremark_stem coremark_${coremark_profile}
foreach suffix {.hex _data.hex _config.vh} {
    if {![file exists programs/${coremark_stem}${suffix}]} {
        error "Missing programs/${coremark_stem}${suffix}; run build_coremark.bat"
    }
}
if {![file exists build]} {file mkdir build}
if {![file exists modelsim.ini]} {vmap -c}
set coremark_lib ${coremark_stem}_work
if {![file isdirectory $coremark_lib]} {vlib $coremark_lib}
vmap $coremark_lib $coremark_lib
set coremark_define +define+COREMARK_CONFIG=\"programs/${coremark_stem}_config.vh\"
vlog -sv -work $coremark_lib $coremark_define \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v \
    rtl/alu.v rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/gpio_mmio.v \
    rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/machine_timer.v \
    rtl/cpu_top.v tb/coremark_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/${coremark_stem}.wlf $coremark_lib.coremark_tb
add wave sim:/coremark_tb/test_pass
foreach signal {clk rst_n pc_x instr_x retire_valid wb_pc cycle_count instret_count snapshots observed_start observed_stop stored_total} {
    add wave sim:/coremark_tb/$signal
}
foreach signal {timer_mtime timer_mtimecmp timer_mtip csr_mstatus csr_mie mem_req_fire mem_addr_x mmio_putchar_valid mmio_putchar_data} {
    add wave sim:/coremark_tb/dut/$signal
}
run -all
if {[examine -radix unsigned sim:/coremark_tb/test_pass] != 1} {error "CoreMark $coremark_profile stopped without PASS"}
echo "CoreMark $coremark_profile test_pass=1"
catch {wave zoom full}
