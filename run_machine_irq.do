# Future source-only directed tests. This script builds no firmware and never
# programs hardware. It has not been executed for the new machine IRQ sources.
onerror {quit -code 1 -f}
catch {quit -sim}
foreach source {rtl/branch_predictor.v rtl/axi_lite_irq_demo.v tb/machine_irq_cpu_tb.v tb/axi_lite_irq_demo_tb.v} {
    if {![file exists $source]} {error "Missing $source; install the machine IRQ sources first"}
}
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build]} {file mkdir build}
if {![file isdirectory machine_irq_work]} {vlib machine_irq_work}
vmap machine_irq_work machine_irq_work
vlog -sv -work machine_irq_work \
    rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v \
    rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v rtl/data_bus_adapter.v \
    rtl/uart_tx.v rtl/uart_rx.v rtl/uart_rx_fifo.v rtl/uart_rx_mmio.v \
    rtl/gpio_mmio.v rtl/machine_timer.v rtl/cpu_top.v rtl/axi_lite_irq_demo.v \
    tb/machine_irq_cpu_tb.v tb/axi_lite_irq_demo_tb.v
foreach machine_irq_bench {axi_lite_irq_demo_tb machine_irq_cpu_tb} {
    catch {quit -sim}
    vsim -voptargs="+acc" -onfinish stop -wlf build/${machine_irq_bench}.wlf machine_irq_work.$machine_irq_bench
    add wave sim:/$machine_irq_bench/test_pass
    if {$machine_irq_bench eq "machine_irq_cpu_tb"} {
        add wave sim:/$machine_irq_bench/done
        foreach machine_irq_case {external_masks software_masks timer_mask priority_off priority_on level_reentry request_wait response_wait fault_priority default_off msip_access_errors} {
            foreach machine_irq_signal {clk rst_n irq_external pc_x trap_valid trap_pc trap_cause trap_tval irqs syncs mret_retired} {
                add wave sim:/$machine_irq_bench/$machine_irq_case/$machine_irq_signal
            }
        }
    } else {
        foreach machine_irq_signal {clk rst_n irq awvalid awready wvalid wready bvalid bresp arvalid arready rvalid rresp rdata} {
            add wave sim:/$machine_irq_bench/$machine_irq_signal
        }
    }
    run -all
    if {[examine -radix unsigned sim:/$machine_irq_bench/test_pass] != 1} {error "$machine_irq_bench stopped without PASS"}
    echo "$machine_irq_bench test_pass=1"
}
echo "MACHINE IRQ DIRECTED TESTS PASS (no physical board verification)"
catch {wave zoom full}
unset -nocomplain source machine_irq_bench machine_irq_case machine_irq_signal
