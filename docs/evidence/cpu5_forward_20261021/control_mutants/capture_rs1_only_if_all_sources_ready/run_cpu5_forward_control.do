onerror {quit -code 1 -force}
file mkdir build/cpu5_s3_control
transcript file build/cpu5_s3_control/transcript.log
if {![file exists build/cpu5_s3_control/work]} {vlib build/cpu5_s3_control/work}
vmap cpu5_forward_control_work build/cpu5_s3_control/work
vlog -sv -work cpu5_forward_control_work +incdir+. rtl/alu.v rtl/regfile.v rtl/cpu5_hazard.v rtl/cpu5_alu_decode.v rtl/cpu5_alu_pipeline.v tb/cpu5_forward_control_tb.v
vsim -voptargs=+acc -onfinish stop -wlf build/cpu5_s3_control/control.wlf cpu5_forward_control_work.cpu5_forward_control_tb
log -r /*
run -all
if {[examine -radix unsigned sim:/cpu5_forward_control_tb/test_pass] != 1} {error "CPU5 forwarding control stopped without success"}
quit -code 0 -force
