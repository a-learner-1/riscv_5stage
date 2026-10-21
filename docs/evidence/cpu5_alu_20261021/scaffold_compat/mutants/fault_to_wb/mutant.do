onerror {quit -code 1 -f}
catch {quit -sim}
if {![file isdirectory build/cpu5_s1_scaffold/mutants/fault_to_wb/work]} {vlib build/cpu5_s1_scaffold/mutants/fault_to_wb/work}
vmap cpu5_scaffold_mutant_fault_to_wb build/cpu5_s1_scaffold/mutants/fault_to_wb/work
vlog -sv +incdir+. -work cpu5_scaffold_mutant_fault_to_wb build/cpu5_s1_scaffold/mutants/fault_to_wb/cpu5_pipeline_skeleton.v tb/cpu5_pipeline_skeleton_tb.v
vsim -voptargs="+acc" -onfinish stop cpu5_scaffold_mutant_fault_to_wb.cpu5_pipeline_skeleton_tb +SCAFFOLD_TRACE_DIR=build/cpu5_s1_scaffold/mutants/fault_to_wb
run -all
if {[examine -radix unsigned sim:/cpu5_pipeline_skeleton_tb/test_pass] != 1} {error "Must-fail mutated pipeline"}
quit -code 0 -f
