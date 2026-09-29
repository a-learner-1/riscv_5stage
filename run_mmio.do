quit -sim
if {[file exists work]} {vdel -lib work -all}
vlib work
vmap work work

vlog -reportprogress 300 -sv -work work \
    rtl/instr_mem.v rtl/if_stage.v rtl/regfile.v rtl/decoder.v \
    rtl/alu.v rtl/data_mem.v rtl/cpu_top.v tb/mmio_tb.v

vsim -voptargs="+acc" -onfinish stop -wlf mmio_run.wlf work.mmio_tb
add wave sim:/mmio_tb/clk
add wave sim:/mmio_tb/rst_n
add wave -radix hexadecimal sim:/mmio_tb/pc_x
add wave -radix hexadecimal sim:/mmio_tb/instr_x
add wave sim:/mmio_tb/valid_x
add wave sim:/mmio_tb/dut/load_pending
add wave -radix hexadecimal sim:/mmio_tb/dut/mem_addr_x
add wave sim:/mmio_tb/mmio_putchar_valid
add wave -radix ascii sim:/mmio_tb/mmio_putchar_data
add wave -radix unsigned sim:/mmio_tb/cycle_count
add wave -radix unsigned sim:/mmio_tb/instret_count

run -all
wave zoom full
