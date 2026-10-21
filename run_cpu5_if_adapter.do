onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/cpu5_s1_if
transcript file build/cpu5_s1_if/modelsim_transcript.log
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/cpu5_s1_if/work]} {vlib build/cpu5_s1_if/work}
vmap cpu5_s1_if_work build/cpu5_s1_if/work
vlog -sv -work cpu5_s1_if_work rtl/instr_mem.v rtl/instr_bus_adapter.v rtl/branch_predictor.v rtl/if_stage.v rtl/cpu5_if_adapter.v tb/cpu5_if_adapter_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/cpu5_s1_if/observation.wlf cpu5_s1_if_work.cpu5_if_adapter_tb
log -r sim:/cpu5_if_adapter_tb/*
run -all
if {[examine -radix unsigned sim:/cpu5_if_adapter_tb/test_pass] != 1} {error "IF adapter stopped before all seven gates passed"}
echo "CPU5 IF SEVEN GATES PASS; CPU5 full pipeline / STA / board NOT RUN"
catch {quit -sim}
transcript file build/cpu5_s1_if/sequence_exhaustion_transcript.log
vsim -voptargs="+acc" -onfinish stop -wlf build/cpu5_s1_if/sequence_exhaustion.wlf cpu5_s1_if_work.cpu5_if_adapter_tb +IF_SEQ_EXHAUST
log -r sim:/cpu5_if_adapter_tb/*
run -all
if {[examine -radix unsigned sim:/cpu5_if_adapter_tb/negative_expected] != 1 || [examine -radix unsigned sim:/cpu5_if_adapter_tb/negative_returned] != 0 || [examine -radix unsigned sim:/cpu5_if_adapter_tb/dut/seq_exhausted] != 1 || [examine -radix unsigned sim:/cpu5_if_adapter_tb/dut/raw_valid] != 1 || [examine -radix unsigned sim:/cpu5_if_adapter_tb/ifid_valid] != 0 || [examine -radix unsigned sim:/cpu5_if_adapter_tb/imem_rsp_ready] != 0} {error "Expected terminal halt/fatal did not stop transfer and response"}
echo "CPU5 IF EXPECTED SEQUENCE EXHAUSTION REJECT PASS (one intentional Fatal)"
catch {quit -sim}
quit -code 0 -f
