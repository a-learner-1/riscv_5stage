# New timer IRQ board FUNCTIONAL netlist test. No SDF or hardware download.
onerror {quit -code 1 -f}
catch {quit -sim}
set netlist build/pds_timer_irq_board/synthesize/board_top_syn.vm
if {![file exists $netlist]} {error "Run build_pds_board.bat --variant timer_irq_board first"}
# Reject a stale synthesized netlist even when the old file still exists.
exec python -c {
import hashlib, json
from pathlib import Path
root = Path.cwd()
import sys
sys.path.insert(0, 'tools')
from build_pds_board import validate_timer_irq_board_firmware
validate_timer_irq_board_firmware(root)
manifest = json.loads((root/'build/pds_timer_irq_board/build_manifest.json').read_text())
assert manifest['variant'] == 'timer_irq_board' and manifest['firmware'] == 'timer_irq_board', 'Wrong PDS variant'
assert manifest['enable_traps'] == 1 and manifest['enable_timer_irq'] == 1, 'Timer IRQ mode disabled'
assert manifest['clock_hz'] == 50000000 and manifest['uart_baud'] == 115200, 'Wrong clock/UART'
for name, digest in manifest['firmware_build_report'].items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest() == digest, 'Stale firmware report'
assert manifest['source_top'] == 'rtl/timer_irq_board_top.v' and manifest['generated_top_module'] == 'board_top', 'Wrong PDS top'
assert hashlib.sha256((root/'tools/build_pds_board.py').read_bytes()).hexdigest() == manifest['build_script_sha256'], 'Stale PDS builder'
for name, digest in manifest['sources'].items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest() == digest, 'Stale PDS source: ' + name
for name, digest in manifest['initialization_files'].items():
    assert hashlib.sha256((root/'programs'/name).read_bytes()).hexdigest() == digest, 'Stale PDS image: ' + name
}
set pds_root D:/pango/PDS_2022.2-SP6.4
if {[info exists env(PDS_HOME)]} {
    set pds_root $env(PDS_HOME)
} elseif {[info exists env(PDS_SHELL)]} {
    set pds_root [file dirname [file dirname $env(PDS_SHELL)]]
}
set models [glob [file join $pds_root arch vendor pango verilog simulation *.v]]
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory timer_irq_board_netlist_work]} {vlib timer_irq_board_netlist_work}
vmap timer_irq_board_netlist_work timer_irq_board_netlist_work
vlog -quiet -sv -work timer_irq_board_netlist_work {*}$models $netlist tb/timer_irq_board_netlist_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf timer_irq_board_netlist_run.wlf timer_irq_board_netlist_work.timer_irq_board_netlist_tb
add wave sim:/timer_irq_board_netlist_tb/test_pass
add wave sim:/timer_irq_board_netlist_tb/boots
add wave sim:/timer_irq_board_netlist_tb/clk_50m
add wave sim:/timer_irq_board_netlist_tb/key1_n
add wave sim:/timer_irq_board_netlist_tb/led
add wave sim:/timer_irq_board_netlist_tb/uart_tx
run -all
if {[examine -radix unsigned sim:/timer_irq_board_netlist_tb/test_pass] != 1} {
    error "Timer IRQ board netlist stopped without PASS"
}
echo "Timer IRQ board netlist test_pass=1"
catch {wave zoom full}
