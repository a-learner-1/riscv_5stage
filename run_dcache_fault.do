onerror {quit -code 1 -f}
catch {quit -sim}
if {![file exists modelsim.ini]} {vmap -c}
if {![file exists dcache_work]} {vlib dcache_work}
vmap dcache_work dcache_work
vlog -sv -work dcache_work {*}[glob rtl/*.v] tb/dcache_fault_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/dcache_fault.wlf dcache_work.dcache_fault_tb
add wave sim:/dcache_fault_tb/test_pass
add wave -radix hexadecimal sim:/dcache_fault_tb/done
run -all
if {[examine -radix unsigned sim:/dcache_fault_tb/test_pass] != 1} {error "Data cache CPU faults stopped without PASS"}
echo "DCACHE CPU FAULT TESTS PASS"
