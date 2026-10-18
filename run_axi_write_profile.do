# STORE stage profiling only; no RTL, firmware or hardware modification.
onerror {quit -code 1 -f}
catch {quit -sim}
if {![file isdirectory build]} {file mkdir build}
if {![file exists modelsim.ini]} {vmap -c}
set write_profile_lib axi_write_profile_work
if {![file isdirectory $write_profile_lib]} {vlib $write_profile_lib}
vmap $write_profile_lib $write_profile_lib
vlog -sv -work $write_profile_lib \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v \
    rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v rtl/data_bus_adapter.v \
    rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v \
    rtl/gpio_mmio.v rtl/machine_timer.v rtl/cpu_top.v rtl/soc_instr_mem.v \
    rtl/instr_cache.v rtl/data_cache.v rtl/dmem_axi_lite_bridge.v \
    rtl/soc_axi_lite_top.v rtl/axi_lite_1x2.v rtl/axi_lite_ram.v \
    tb/axi_write_profile_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/axi_write_profile.wlf $write_profile_lib.axi_write_profile_tb
log -r sim:/axi_write_profile_tb/*
add wave sim:/axi_write_profile_tb/test_pass
foreach write_profile_case {off_zero on_zero on_b_stall} {
    set write_profile_path sim:/axi_write_profile_tb/$write_profile_case
    add wave -group $write_profile_case $write_profile_path/rst_n $write_profile_path/active
    add wave -group $write_profile_case -radix unsigned \
        $write_profile_path/cycle $write_profile_path/t_launch \
        $write_profile_path/t_cpu_req $write_profile_path/t_bridge_req \
        $write_profile_path/t_up_pair $write_profile_path/t_down_pair \
        $write_profile_path/t_commit $write_profile_path/t_ram_b \
        $write_profile_path/t_up_bhs $write_profile_path/t_cpu_rsp $write_profile_path/t_retire
    add wave -group $write_profile_case \
        $write_profile_path/cq_valid $write_profile_path/cq_ready \
        $write_profile_path/uav $write_profile_path/uaw $write_profile_path/uwv $write_profile_path/uww \
        $write_profile_path/dav $write_profile_path/daw $write_profile_path/dwv $write_profile_path/dww \
        $write_profile_path/ram/u_data_mem/we $write_profile_path/dbv $write_profile_path/dbr \
        $write_profile_path/ubv $write_profile_path/ubr $write_profile_path/cp_valid $write_profile_path/cp_ready \
        $write_profile_path/retire_valid
}
run -all
if {[examine -radix unsigned sim:/axi_write_profile_tb/test_pass] != 1} {
    error "AXI write profile stopped without PASS"
}
echo "AXI WRITE PROFILE test_pass=1"
catch {wave zoom full}
unset -nocomplain write_profile_lib write_profile_case write_profile_path
