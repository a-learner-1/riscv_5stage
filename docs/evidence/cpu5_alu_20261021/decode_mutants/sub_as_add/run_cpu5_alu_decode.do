onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/cpu5_s2_decode
transcript file build/cpu5_s2_decode/modelsim_transcript.log
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/cpu5_s2_decode/work]} {vlib build/cpu5_s2_decode/work}
vmap cpu5_s2_decode_work build/cpu5_s2_decode/work
vlog -sv -work cpu5_s2_decode_work rtl/alu.v rtl/cpu5_alu_decode.v tb/cpu5_alu_decode_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/cpu5_s2_decode/decode.wlf cpu5_s2_decode_work.cpu5_alu_decode_tb
log -r sim:/cpu5_alu_decode_tb/*
run -all
if {[examine -radix unsigned sim:/cpu5_alu_decode_tb/test_pass] != 1} {error "ALU decode test stopped without success"}
echo "CPU5 21-INSTRUCTION ALU DECODE DIRECTED TEST PASS"
catch {quit -sim}
quit -code 0 -f
