onerror {quit -code 1 -f}
# The launcher snapshots sources and creates a private ini/library/cwd per run.
set py {C:/Users/23123/AppData/Local/Programs/Python/Python311/python.exe}
if {[catch {exec $py tools/run_cpu5_d0_control.py} result]} {puts $result;quit -code 1 -f}
puts $result
quit -code 0 -f
