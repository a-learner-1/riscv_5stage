onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/cpu5_s4_branch
transcript file build/cpu5_s4_branch/modelsim_top_transcript.log
exec python -B tools/generate_cpu5_branch_vectors.py
for {set n 0} {$n < 48} {incr n} {file mkdir build/cpu5_s4_branch/cases/case$n}
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/cpu5_s4_branch/top_work]} {vlib build/cpu5_s4_branch/top_work}
vmap cpu5_s4_top_work build/cpu5_s4_branch/top_work
vlog -sv +incdir+. -work cpu5_s4_top_work rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v rtl/alu.v rtl/regfile.v rtl/cpu5_if_adapter.v rtl/cpu5_hazard.v rtl/cpu5_pipeline_skeleton.v rtl/cpu5_alu_decode.v rtl/cpu5_branch_unit.v rtl/cpu5_alu_pipeline.v rtl/cpu5_top.v tb/cpu5_branch_top_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/cpu5_s4_branch/top.wlf cpu5_s4_top_work.cpu5_branch_top_tb
log -r sim:/cpu5_branch_top_tb/g_cases(0)/* sim:/cpu5_branch_top_tb/g_cases(1)/* sim:/cpu5_branch_top_tb/g_cases(6)/* sim:/cpu5_branch_top_tb/g_cases(7)/*
run -all
if {[examine -radix unsigned sim:/cpu5_branch_top_tb/test_pass] != 1} {error "CPU5 branch top stopped without success"}
echo "CPU5 CONTROL-FLOW SUBSET VERIFIED; D/M/CSR/TRAP/IRQ AND FULL PROFILING NOT IMPLEMENTED"
catch {quit -sim}
quit -code 0 -f
