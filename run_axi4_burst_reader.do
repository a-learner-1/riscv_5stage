onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/verification
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/axi4_reader_work]} {vlib build/axi4_reader_work}
vmap axi4_reader_work build/axi4_reader_work
vlog -sv -work axi4_reader_work rtl/axi_lite_burst_reader.v tb/axi4_read_contract_monitor.v tb/axi4_burst_reader_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/verification/axi4_burst_reader.wlf axi4_reader_work.axi4_burst_reader_tb
run -all
if {[examine -radix unsigned sim:/axi4_burst_reader_tb/test_pass] != 1} {puts stderr "AXI4 reader stopped without PASS";quit -code 1 -f}
echo "AXI4 BURST READER test_pass=1"
catch {quit -sim}
