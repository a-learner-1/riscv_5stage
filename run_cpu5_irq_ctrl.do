onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/cpu5_s9_irq_ctrl
transcript file build/cpu5_s9_irq_ctrl/modelsim_transcript.log
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/cpu5_s9_irq_ctrl/work]} {vlib build/cpu5_s9_irq_ctrl/work}
vmap cpu5_s9_irq_ctrl_work build/cpu5_s9_irq_ctrl/work
vlog -sv -work cpu5_s9_irq_ctrl_work rtl/cpu5_csr_unit.v rtl/cpu5_irq_ctrl.v tb/cpu5_irq_ctrl_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/cpu5_s9_irq_ctrl/ctrl.wlf cpu5_s9_irq_ctrl_work.cpu5_irq_ctrl_tb
log -r sim:/cpu5_irq_ctrl_tb/*
run -all
if {[examine -radix unsigned sim:/cpu5_irq_ctrl_tb/test_pass] != 1} {error "IRQ controller test stopped without success"}
echo "CPU5 IRQ CTRL DIRECTED TEST PASS"
catch {quit -sim}
quit -code 0 -f
