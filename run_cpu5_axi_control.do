onerror {quit -code 1 -f}
# The Python launcher snapshots sources into a unique private directory before
# invoking either compiler or simulator. Never map libraries in this cwd.
set py {C:/Users/23123/AppData/Local/Programs/Python/Python311/python.exe}
if {[catch {exec $py tools/run_cpu5_axi_control.py} result]} {puts $result;quit -code 1 -f}
puts $result
quit -code 0 -f
