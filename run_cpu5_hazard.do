# CPU5 source selection contracts only. No legacy sources are changed.
onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/cpu5_s1_hazard
transcript file build/cpu5_s1_hazard/modelsim_transcript.log
if {![file exists modelsim.ini]} {vmap -c}
set hz_lib cpu5_hazard_work
if {![file isdirectory build/$hz_lib]} {vlib build/$hz_lib}
vmap $hz_lib build/$hz_lib
if {![info exists CPU5_HAZARD_SOURCE]} {set CPU5_HAZARD_SOURCE rtl/cpu5_hazard.v}
vlog -sv -work $hz_lib $CPU5_HAZARD_SOURCE tb/cpu5_hazard_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/cpu5_s1_hazard/hazard.wlf $hz_lib.cpu5_hazard_tb
run -all
if {[examine -radix unsigned sim:/cpu5_hazard_tb/test_pass] != 1} {error "CPU5 hazard stopped without the success gate"}
echo "CPU5 HAZARD CONTRACT PASS"
quit -code 0 -f
