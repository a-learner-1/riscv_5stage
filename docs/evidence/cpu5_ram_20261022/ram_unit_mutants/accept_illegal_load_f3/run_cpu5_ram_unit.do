onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/cpu5_s5_ram_unit
transcript file build/cpu5_s5_ram_unit/modelsim_transcript.log
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/cpu5_s5_ram_unit/work]} {vlib build/cpu5_s5_ram_unit/work}
vmap cpu5_s5_ram_unit_work build/cpu5_s5_ram_unit/work
vlog -sv -work cpu5_s5_ram_unit_work rtl/cpu5_ram_unit.v tb/cpu5_ram_unit_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/cpu5_s5_ram_unit/ram_unit.wlf cpu5_s5_ram_unit_work.cpu5_ram_unit_tb
run -all
if {[examine -radix unsigned sim:/cpu5_ram_unit_tb/test_pass] != 1} {error "RAM unit test stopped without success"}
echo "CPU5 RAM UNIT DIRECTED TEST PASS"
catch {quit -sim}
quit -code 0 -f
