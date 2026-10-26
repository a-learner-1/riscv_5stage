onerror {quit -code 1 -f}
transcript file simulation_transcript.log
vmap cpu5_coremark_work work
vsim -voptargs="+acc" -onfinish stop -gCASES=4 -wlf system.wlf cpu5_coremark_work.cpu5_coremark_tb
log -r sim:/cpu5_coremark_tb/*
run -all
if {[examine -radix unsigned sim:/cpu5_coremark_tb/test_pass] != 1} {quit -code 1 -f}
echo "CPU5 COREMARK REFERENCE PASS"
quit -code 0 -f
