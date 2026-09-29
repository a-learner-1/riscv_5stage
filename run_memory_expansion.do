quit -sim
if {[file exists work]} {vdel -lib work -all}
vlib work
vmap work work

vlog -reportprogress 300 -sv -work work \
    rtl/instr_mem.v rtl/data_mem.v \
    tb/instr_mem_tb.v tb/data_mem_tb.v

vsim -voptargs="+acc" -onfinish stop work.instr_mem_tb
run -all
quit -sim

vsim -voptargs="+acc" -onfinish stop -wlf memory_expansion_run.wlf work.data_mem_tb
add wave sim:/data_mem_tb/clk
add wave -radix hexadecimal sim:/data_mem_tb/addr
add wave sim:/data_mem_tb/re
add wave sim:/data_mem_tb/we
add wave -radix hexadecimal sim:/data_mem_tb/rdata
add wave sim:/data_mem_tb/access_ok
add wave -radix hexadecimal sim:/data_mem_tb/init_addr
add wave -radix hexadecimal sim:/data_mem_tb/init_rdata
add wave sim:/data_mem_tb/init_access_ok
run -all
wave zoom full
