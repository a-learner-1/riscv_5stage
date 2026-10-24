onerror {quit -code 1 -f}
exec python -B tools/run_cpu5_machine_control.py
echo "CPU5 MACHINE CONTROL PRIVATE VERIFICATION PASS"
quit -code 0 -f
