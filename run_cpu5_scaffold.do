onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/cpu5_s1_scaffold
transcript file build/cpu5_s1_scaffold/modelsim_transcript.log
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/cpu5_s1_scaffold/work]} {vlib build/cpu5_s1_scaffold/work}
vmap cpu5_s1_scaffold_work build/cpu5_s1_scaffold/work
vlog -sv +incdir+. -work cpu5_s1_scaffold_work rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v rtl/cpu5_if_adapter.v rtl/cpu5_hazard.v rtl/cpu5_pipeline_skeleton.v rtl/cpu5_top.v tb/cpu5_pipeline_skeleton_tb.v tb/cpu5_top_scaffold_tb.v
foreach bench {cpu5_pipeline_skeleton_tb cpu5_top_scaffold_tb} {
    catch {quit -sim}
    vsim -voptargs="+acc" -onfinish stop -wlf build/cpu5_s1_scaffold/${bench}.wlf cpu5_s1_scaffold_work.$bench
    log -r sim:/$bench/*
    run -all
    if {[examine -radix unsigned sim:/$bench/test_pass] != 1} {error "$bench stopped without success"}
}
echo "CPU5 METADATA SCAFFOLD VERIFIED; ISA/RETIRE/D/CSR/M/IRQ NOT IMPLEMENTED"
catch {quit -sim}
quit -code 0 -f
