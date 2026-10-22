onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/cpu5_s5_ram_control
transcript file build/cpu5_s5_ram_control/modelsim_transcript.log
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/cpu5_s5_ram_control/work]} {vlib build/cpu5_s5_ram_control/work}
vmap cpu5_s5_ram_control_work build/cpu5_s5_ram_control/work
vlog -sv -work cpu5_s5_ram_control_work rtl/alu.v rtl/regfile.v rtl/cpu5_alu_decode.v rtl/cpu5_branch_unit.v rtl/cpu5_hazard.v rtl/cpu5_ram_unit.v rtl/cpu5_ram_owner.v rtl/cpu5_alu_pipeline.v tb/cpu5_ram_control_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/cpu5_s5_ram_control/ram_control.wlf cpu5_s5_ram_control_work.cpu5_ram_control_tb
log -r sim:/cpu5_ram_control_tb/*
run -all
if {[examine -radix unsigned sim:/cpu5_ram_control_tb/test_pass] != 1} {error "RAM control test stopped without success"}
echo "CPU5 RAM CONTROL DIRECTED TEST PASS"
catch {quit -sim}
quit -code 0 -f
