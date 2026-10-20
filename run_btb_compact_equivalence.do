onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/verification
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/btb_compact_work]} {vlib build/btb_compact_work}
vmap btb_compact_work build/btb_compact_work
vlog -sv -work btb_compact_work rtl/branch_predictor.v tb/branch_predictor_reference_f115192.v tb/btb_compact_equivalence_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/verification/btb_compact_equivalence.wlf btb_compact_work.btb_compact_equivalence_tb
run -all
if {[examine -radix unsigned sim:/btb_compact_equivalence_tb/test_pass] != 1} {puts stderr "BTB compact equivalence stopped without PASS";quit -code 1 -f}
echo "BTB COMPACT EQUIVALENCE test_pass=1"
catch {quit -sim}
