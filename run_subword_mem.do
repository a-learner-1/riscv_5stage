quit -sim
if {[file exists work]} {vdel -lib work -all}
vlib work
vmap work work
vlog -reportprogress 300 -sv -work work rtl/instr_mem.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v rtl/alu.v rtl/data_mem.v rtl/uart_tx.v rtl/cpu_top.v tb/load_store_decoder_tb.v tb/data_mem_tb.v tb/subword_mem_tb.v

vsim -voptargs=+acc -onfinish stop work.load_store_decoder_tb
run -all
quit -sim

vsim -voptargs=+acc -onfinish stop work.data_mem_tb
run -all
quit -sim

vsim -voptargs=+acc -onfinish stop -wlf cpu_subword_run.wlf work.subword_mem_tb
add wave sim:/subword_mem_tb/*
add wave sim:/subword_mem_tb/dut/is_lb_x
add wave sim:/subword_mem_tb/dut/is_lbu_x
add wave sim:/subword_mem_tb/dut/is_lh_x
add wave sim:/subword_mem_tb/dut/is_lhu_x
add wave sim:/subword_mem_tb/dut/is_sb_x
add wave sim:/subword_mem_tb/dut/is_sh_x
add wave sim:/subword_mem_tb/dut/mem_addr_x
add wave sim:/subword_mem_tb/dut/mem_size_x
add wave sim:/subword_mem_tb/dut/mem_wdata_x
add wave sim:/subword_mem_tb/dut/mem_wstrb_x
add wave sim:/subword_mem_tb/dut/mem_rdata_x
add wave sim:/subword_mem_tb/dut/load_data_x
add wave sim:/subword_mem_tb/dut/forward_rs1_x
add wave sim:/subword_mem_tb/dut/forward_rs2_x
run -all
wave zoom full
