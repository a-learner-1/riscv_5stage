catch {quit -sim}
if {![file exists modelsim.ini]} {vmap -c}
if {![file exists uart_unit_work]} {vlib uart_unit_work}
vmap uart_unit_work uart_unit_work
vlog -sv -work uart_unit_work rtl/uart_tx.v tb/uart_tx_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf uart_unit_run.wlf uart_unit_work.uart_tx_tb
add wave sim:/uart_tx_tb/clk
add wave sim:/uart_tx_tb/rst_n
add wave sim:/uart_tx_tb/valid
add wave -radix hexadecimal sim:/uart_tx_tb/data
add wave sim:/uart_tx_tb/tx
add wave sim:/uart_tx_tb/busy
add wave sim:/uart_tx_tb/done
run -all
catch {wave zoom full}
