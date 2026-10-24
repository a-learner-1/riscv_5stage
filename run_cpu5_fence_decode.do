onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/cpu5_s12_fence_decode
transcript file build/cpu5_s12_fence_decode/modelsim_transcript.log
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/cpu5_s12_fence_decode/work]} {vlib build/cpu5_s12_fence_decode/work}
vmap fence_decode_work build/cpu5_s12_fence_decode/work
vlog -sv +incdir+. -work fence_decode_work rtl/alu.v rtl/regfile.v rtl/cpu5_alu_decode.v rtl/cpu5_branch_unit.v rtl/cpu5_hazard.v rtl/cpu5_ram_unit.v rtl/cpu5_ram_owner.v rtl/cpu5_csr_unit.v rtl/cpu5_irq_ctrl.v rtl/rv32m_unit.v rtl/cpu5_m_owner.v rtl/cpu5_alu_pipeline.v tb/cpu5_fence_decode_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/cpu5_s12_fence_decode/fence_decode.wlf fence_decode_work.cpu5_fence_decode_tb
log -r sim:/cpu5_fence_decode_tb/*
run -all
if {[examine -radix unsigned sim:/cpu5_fence_decode_tb/test_pass] != 1} {error "FENCE decode stopped without success"}
echo "CPU5 FENCE DECODE REFERENCE PASS"
catch {quit -sim}
quit -code 0 -f
