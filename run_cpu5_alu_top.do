onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/cpu5_s2_alu
transcript file build/cpu5_s2_alu/modelsim_transcript.log
exec python -B tools/generate_cpu5_alu_vectors.py
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/cpu5_s2_alu/work]} {vlib build/cpu5_s2_alu/work}
vmap cpu5_s2_alu_work build/cpu5_s2_alu/work
vlog -sv +incdir+. -work cpu5_s2_alu_work rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v rtl/alu.v rtl/regfile.v rtl/cpu5_if_adapter.v rtl/cpu5_hazard.v rtl/cpu5_pipeline_skeleton.v rtl/cpu5_alu_decode.v rtl/cpu5_alu_pipeline.v rtl/cpu5_top.v tb/cpu5_alu_top_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/cpu5_s2_alu/top.wlf cpu5_s2_alu_work.cpu5_alu_top_tb
log -r sim:/cpu5_alu_top_tb/fast/* sim:/cpu5_alu_top_tb/waited/* sim:/cpu5_alu_top_tb/fetch_error/*
run -all
if {[examine -radix unsigned sim:/cpu5_alu_top_tb/test_pass] != 1} {error "CPU5 ALU top stopped without success"}
echo "CPU5 STAGE 3A-1 ALU SUBSET TOP VERIFIED; FULL ISA/TRAPS/D/M/CSR/IRQ NOT IMPLEMENTED"
catch {quit -sim}
quit -code 0 -f
