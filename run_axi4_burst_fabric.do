onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/verification
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/axi4_fabric_work]} {vlib build/axi4_fabric_work}
vmap axi4_fabric_work build/axi4_fabric_work
vlog -sv -work axi4_fabric_work rtl/data_mem.v rtl/axi4_read_ram.v rtl/axi4_read_1x2.v tb/axi4_read_contract_monitor.v tb/axi4_burst_fabric_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/verification/axi4_burst_fabric.wlf axi4_fabric_work.axi4_burst_fabric_tb
run -all
if {[examine -radix unsigned sim:/axi4_burst_fabric_tb/test_pass] != 1} {puts stderr "AXI4 fabric stopped without PASS";quit -code 1 -f}
echo "AXI4 BURST FABRIC test_pass=1"
catch {quit -sim}
