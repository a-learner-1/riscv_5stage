onerror {quit -code 1 -f}
catch {quit -sim}
foreach image {c_demo.hex c_demo_data.hex data_handshake_blank.hex} {
    if {![file exists programs/$image]} {error "Missing existing programs/$image"}
}
# Optional targeted repair run: set axi_tests {bridge}, {ram}, or {cpu} first.
if {![info exists axi_tests]} {set axi_tests {bridge ram cpu}}
foreach test $axi_tests {
    if {$test ni {bridge ram cpu}} {error "Unknown AXI test $test"}
}
if {[llength $axi_tests] == 0} {error "No AXI tests selected"}
if {![file exists modelsim.ini]} {vmap -c}
set axi_lib axi_lite_work
if {![file exists $axi_lib]} {vlib $axi_lib}
vmap $axi_lib $axi_lib
vlog -sv -work $axi_lib \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/if_stage.v \
    rtl/regfile.v rtl/decoder.v rtl/alu.v \
    rtl/data_mem.v rtl/data_bus_adapter.v rtl/uart_tx.v rtl/uart_rx.v \
    rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v rtl/gpio_mmio.v rtl/cpu_top.v \
    rtl/soc_instr_mem.v rtl/dmem_axi_lite_bridge.v rtl/axi_lite_ram.v \
    rtl/soc_axi_lite_top.v \
    tb/axi_lite_bridge_tb.v tb/axi_lite_ram_tb.v tb/axi_lite_cpu_tb.v
foreach test $axi_tests {
    catch {quit -sim}
    set top axi_lite_${test}_tb
    vsim -voptargs="+acc" -onfinish stop -wlf axi_lite_${test}_run.wlf $axi_lib.$top
    if {$test eq "cpu"} {
        add wave sim:/axi_lite_cpu_tb/done
        add wave sim:/axi_lite_cpu_tb/test_pass
        add wave sim:/axi_lite_cpu_tb/c_wait/clk
        add wave sim:/axi_lite_cpu_tb/c_wait/rst_n
        foreach signal {awvalid awready wvalid wready bvalid bready arvalid arready rvalid rready} {
            add wave sim:/axi_lite_cpu_tb/c_wait/dut/$signal
        }
        foreach signal {awaddr wdata wstrb bresp araddr rdata rresp} {
            add wave -radix hexadecimal sim:/axi_lite_cpu_tb/c_wait/dut/$signal
        }
        add wave sim:/axi_lite_cpu_tb/c_wait/dut/u_soc/dmem_req_valid
        add wave sim:/axi_lite_cpu_tb/c_wait/dut/u_soc/dmem_req_ready
        add wave sim:/axi_lite_cpu_tb/c_wait/dut/u_soc/dmem_rsp_valid
        add wave sim:/axi_lite_cpu_tb/c_wait/dut/u_soc/dmem_rsp_ready
        add wave sim:/axi_lite_cpu_tb/c_wait/dut/u_soc/retire_valid
        add wave -radix hexadecimal sim:/axi_lite_cpu_tb/c_wait/dut/u_soc/wb_pc
        add wave sim:/axi_lite_cpu_tb/c_wait/dut/u_soc/dmem_fault
    } else {
        add wave sim:/$top/test_pass
    }
    run -all
    if {[examine -radix unsigned sim:/$top/test_pass] != 1} {
        error "AXI $test stopped without PASS"
    }
    echo "AXI $test test_pass=1"
}
unset axi_tests
catch {wave zoom full}
