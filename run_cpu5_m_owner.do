onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/cpu5_s8_m_owner
transcript file build/cpu5_s8_m_owner/modelsim_transcript.log
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/cpu5_s8_m_owner/work]} {vlib build/cpu5_s8_m_owner/work}
vmap cpu5_s8_m_owner_work build/cpu5_s8_m_owner/work
vlog -sv -work cpu5_s8_m_owner_work rtl/rv32m_unit.v rtl/cpu5_m_owner.v tb/cpu5_m_owner_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/cpu5_s8_m_owner/owner.wlf cpu5_s8_m_owner_work.cpu5_m_owner_tb
log -r sim:/cpu5_m_owner_tb/*
run -all
if {[examine -radix unsigned sim:/cpu5_m_owner_tb/test_pass] != 1} {error "M owner test stopped without success"}
echo "CPU5 M OWNER DIRECTED TEST PASS"
catch {quit -sim}
quit -code 0 -f
