onerror {quit -code 1 -f}
catch {quit -sim}
file mkdir build/verification
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory build/d0_native_work]} {vlib build/d0_native_work}
vmap d0_native_work build/d0_native_work
vlog -sv -work d0_native_work rtl/data_mem.v rtl/data_bus_adapter.v rtl/soc_data_mem.v rtl/dmem_region_router.v tb/d0_native_backend_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf build/verification/d0_native_backend.wlf d0_native_work.d0_native_backend_tb
run -all
if {[examine -radix unsigned sim:/d0_native_backend_tb/test_pass] != 1} {puts stderr "D0 native backend stopped without PASS";quit -code 1 -f}
echo "D0 NATIVE BACKEND test_pass=1"
catch {quit -sim}
