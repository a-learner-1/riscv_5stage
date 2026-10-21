onerror {quit -code 1 -f}
catch {quit -sim}
# Repair only the changed group: set axi_control_tests {router}, {ctrl}, or {system}.
if {![info exists axi_control_tests]} {set axi_control_tests {router ctrl system}}
if {[llength $axi_control_tests] == 0} {error "No AXI control tests selected"}
set control_sources [list \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v \
    rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v \
    rtl/uart_rx_mmio.v rtl/gpio_mmio.v rtl/rv32m_unit.v rtl/cpu_top.v rtl/soc_instr_mem.v \
    rtl/dmem_axi_lite_bridge.v rtl/axi_lite_ram.v rtl/soc_axi_lite_top.v \
    rtl/axi_lite_1x2.v rtl/axi_lite_ctrl.v rtl/soc_axi_control_top.v]
foreach test $axi_control_tests {
    switch $test {
        router {lappend control_sources tb/axi_lite_1x2_tb.v}
        ctrl {lappend control_sources tb/axi_lite_ctrl_tb.v}
        system {
            foreach image {axi_control_demo.hex axi_control_demo_data.hex data_handshake_blank.hex} {
                if {![file exists programs/$image]} {error "Missing programs/$image; run build_axi_control.bat"}
            }
            lappend control_sources tb/axi_control_system_tb.v
        }
        default {error "Unknown AXI control test $test"}
    }
}
if {![file exists modelsim.ini]} {vmap -c}
set control_lib axi_control_work
if {![file exists $control_lib]} {vlib $control_lib}
vmap $control_lib $control_lib
eval vlog -sv -work $control_lib $control_sources
foreach test $axi_control_tests {
    catch {quit -sim}
    switch $test {
        router {set top axi_lite_1x2_tb}
        ctrl {set top axi_lite_ctrl_tb}
        system {set top axi_control_system_tb}
    }
    vsim -voptargs="+acc" -onfinish stop -wlf axi_control_${test}_run.wlf $control_lib.$top
    add wave sim:/$top/test_pass
    if {$test eq "system"} {
        add wave sim:/$top/done
        add wave sim:/$top/c_aw_first/clk
        add wave sim:/$top/c_aw_first/rst_n
        foreach prefix {axi ram ctrl} {
            foreach signal {awvalid awready wvalid wready bvalid bready arvalid arready rvalid rready} {
                add wave sim:/$top/c_aw_first/dut/${prefix}_${signal}
            }
            foreach signal {awaddr wdata wstrb bresp araddr rdata rresp} {
                add wave -radix hexadecimal sim:/$top/c_aw_first/dut/${prefix}_${signal}
            }
        }
        foreach signal {ctrl_busy ctrl_done ctrl_result ctrl_start_count dmem_fault} {
            add wave sim:/$top/c_aw_first/dut/$signal
        }
        add wave sim:/$top/c_aw_first/dut/u_core/dmem_req_valid
        add wave sim:/$top/c_aw_first/dut/u_core/dmem_req_ready
        add wave sim:/$top/c_aw_first/dut/u_core/dmem_rsp_valid
        add wave sim:/$top/c_aw_first/dut/u_core/dmem_rsp_ready
        add wave sim:/$top/c_aw_first/dut/retire_valid
        add wave -radix hexadecimal sim:/$top/c_aw_first/dut/wb_pc
    }
    run -all
    if {[examine -radix unsigned sim:/$top/test_pass] != 1} {error "AXI control $test stopped without PASS"}
    echo "AXI control $test test_pass=1"
}
unset axi_control_tests
catch {wave zoom full}
