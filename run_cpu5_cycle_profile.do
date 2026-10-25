onerror {quit -code 1 -f}
set py {C:/Users/23123/AppData/Local/Programs/Python/Python311/python.exe}
if {[catch {exec $py -B tools/run_cpu5_cycle_profile.py} result]} {puts $result;quit -code 1 -f}
puts $result
quit -code 0 -f
