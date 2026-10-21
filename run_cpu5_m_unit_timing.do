onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/cpu5_s05_m/unit_directed
transcript file build/cpu5_s05_m/unit_directed/modelsim_transcript.log
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/cpu5_m_unit_work]} {vlib build/cpu5_m_unit_work}
vmap cpu5_m_unit_work build/cpu5_m_unit_work
vlog -sv -work cpu5_m_unit_work rtl/rv32m_unit.v tb/cpu5_m_unit_timing_tb.v
vsim -voptargs=+acc -onfinish stop -wlf build/cpu5_s05_m/unit_directed/observation.wlf cpu5_m_unit_work.cpu5_m_unit_timing_tb +M_OUTPUT=build/cpu5_s05_m/unit_directed
log sim:/cpu5_m_unit_timing_tb/* sim:/cpu5_m_unit_timing_tb/dut/*
run -all
if {[examine -radix unsigned sim:/cpu5_m_unit_timing_tb/test_pass] != 1} {error "Unit timing directed test failed"}
catch {quit -sim}
quit -code 0 -f
