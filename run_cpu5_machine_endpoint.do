onerror {quit -code 1 -f}
set repository [pwd]
file mkdir build/cpu5_s11_machine_endpoint_manual
cd build/cpu5_s11_machine_endpoint_manual
file mkdir build/cpu5_s11_machine_endpoint
transcript file transcript.log
vmap -c
vlib work
vmap machine_work work
vlog -sv -work machine_work "$repository/rtl/machine_timer.v" "$repository/rtl/cpu5_machine_endpoint.v" "$repository/tb/cpu5_machine_endpoint_tb.v"
vsim -voptargs="+acc" -onfinish stop -wlf endpoint.wlf machine_work.cpu5_machine_endpoint_tb
log -r sim:/*
run -all
if {[examine -radix unsigned sim:/cpu5_machine_endpoint_tb/test_pass] != 1} {quit -code 1 -f}
echo "CPU5 MACHINE ENDPOINT REFERENCE PASS"
quit -code 0 -f
