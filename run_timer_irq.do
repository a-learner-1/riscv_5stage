# Only the new timer, precise IRQ and real C/AXI paths. No unchanged regression.
# Use an ASCII project root with ModelSim 10.6e on Windows.
onerror {quit -code 1 -f}
catch {quit -sim}
if {![file exists build]} {file mkdir build}
if {![file exists modelsim.ini]} {vmap -c}
if {![file exists timer_irq_work]} {vlib timer_irq_work}
vmap timer_irq_work timer_irq_work
vlog -sv -work timer_irq_work {*}[glob rtl/*.v] \
    tb/machine_timer_tb.v tb/timer_irq_tb.v tb/timer_irq_c_tb.v
if {![info exists timer_new_start]} {set timer_new_start 0}
foreach bench [lrange {machine_timer_tb timer_irq_tb timer_irq_c_tb} $timer_new_start end] {
    catch {quit -sim}
    echo "TIMER NEW BEGIN $bench"
    vsim -voptargs="+acc" -onfinish stop -wlf build/timer_new_${bench}.wlf timer_irq_work.$bench
    add wave sim:/$bench/test_pass
    if {$bench != "machine_timer_tb"} {add wave -radix hexadecimal sim:/$bench/done}
    if {$bench == "machine_timer_tb"} {
        foreach signal {clk rst_n addr write_enable write_data read_data mtime mtimecmp mtip} {
            add wave sim:/$bench/$signal
        }
    } elseif {$bench == "timer_irq_tb"} {
        foreach testcase {masks request_wait response_wait fetch_wait level_reentry timer_mmio} {
            foreach signal {clk rst_n pc_x retire_valid wb_pc trap_valid trap_pc trap_cause trap_tval} {
                add wave sim:/$bench/$testcase/$signal
            }
        }
    } else {
        foreach signal {clk rst_n tx trap_valid trap_pc trap_cause retire_valid wb_pc cycles instret} {
            add wave sim:/$bench/aw_first/$signal
        }
        foreach signal {timer_mtime timer_mtimecmp timer_mtip csr_mstatus csr_mie} {
            add wave sim:/$bench/aw_first/dut/u_cpu/$signal
        }
    }
    run -all
    if {[examine -radix unsigned sim:/$bench/test_pass] != 1} {error "$bench stopped without PASS"}
    echo "$bench test_pass=1"
    echo "TIMER NEW END $bench"
    catch {wave zoom full}
}
echo "TIMER NEW TESTS PASS"
