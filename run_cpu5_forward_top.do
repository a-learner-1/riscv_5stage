onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/cpu5_s3_forward
transcript file build/cpu5_s3_forward/modelsim_transcript.log
exec python -B tools/generate_cpu5_alu_vectors.py
exec python -B tools/generate_cpu5_alu_vectors.py --out build/cpu5_s3_forward
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/cpu5_s3_forward/work]} {vlib build/cpu5_s3_forward/work}
vmap cpu5_s3_forward_work build/cpu5_s3_forward/work
vlog -sv +incdir+. -work cpu5_s3_forward_work rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v rtl/alu.v rtl/regfile.v rtl/cpu5_if_adapter.v rtl/cpu5_hazard.v rtl/cpu5_pipeline_skeleton.v rtl/cpu5_alu_decode.v rtl/cpu5_alu_pipeline.v rtl/cpu5_top.v tb/cpu5_alu_top_tb.v tb/cpu5_forward_top_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/cpu5_s3_forward/top.wlf cpu5_s3_forward_work.cpu5_forward_top_tb
log -r sim:/cpu5_forward_top_tb/fast/* sim:/cpu5_forward_top_tb/waited/* sim:/cpu5_forward_top_tb/fetch_error/* sim:/cpu5_forward_top_tb/baseline_fast/* sim:/cpu5_forward_top_tb/baseline_waited/*
run -all
if {[examine -radix unsigned sim:/cpu5_forward_top_tb/test_pass] != 1} {error "CPU5 forwarding top stopped without success"}
echo "CPU5 STAGE 3A-2 INTEGER ALU FORWARDING SUBSET TOP VERIFIED; LOAD/BRANCH/FULL ISA/TRAPS/D/M/CSR/IRQ NOT IMPLEMENTED"
catch {quit -sim}
quit -code 0 -f
