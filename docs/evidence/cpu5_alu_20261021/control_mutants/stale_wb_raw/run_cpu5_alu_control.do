onerror {quit -code 1 -force}
file mkdir build/cpu5_s2_control
transcript file build/cpu5_s2_control/transcript.log
if {![file exists build/cpu5_s2_control/work]} {vlib build/cpu5_s2_control/work}
vmap cpu5_control_work build/cpu5_s2_control/work
vlog -sv -work cpu5_control_work +incdir+. rtl/alu.v rtl/regfile.v rtl/cpu5_alu_decode.v rtl/cpu5_alu_pipeline.v tb/cpu5_alu_control_tb.v
vsim -voptargs=+acc -onfinish stop -wlf build/cpu5_s2_control/control.wlf cpu5_control_work.cpu5_alu_control_tb
log -r /*
run -all
if {[examine -radix unsigned sim:/cpu5_alu_control_tb/test_pass] != 1} {error "CPU5 ALU control stopped without success"}
quit -code 0 -force
