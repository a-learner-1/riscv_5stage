catch {quit -sim}
if {![file exists modelsim.ini]} {vmap -c}
if {![file exists gpio_unit_work]} {vlib gpio_unit_work}
vmap gpio_unit_work gpio_unit_work
vlog -sv -work gpio_unit_work rtl/gpio_mmio.v tb/gpio_unit_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf gpio_unit_run.wlf gpio_unit_work.gpio_unit_tb
add wave sim:/gpio_unit_tb/*
run -all
catch {wave zoom full}
