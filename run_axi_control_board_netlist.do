# New AXI board FUNCTIONAL netlist test. No SDF or hardware download.
onerror {quit -code 1 -f}
catch {quit -sim}
set netlist build/pds_axi_control_board/synthesize/board_top_syn.vm
if {![file exists $netlist]} {error "Run build_pds_board.bat --variant axi_control_board first"}
# Reject an old netlist after an RTL/image change, even if its file still exists.
exec python -c {
import hashlib, json
from pathlib import Path
root = Path.cwd()
manifest = json.loads((root/'build/pds_axi_control_board/build_manifest.json').read_text())
assert manifest['variant'] == 'axi_control_board' and manifest['firmware'] == 'axi_control_board', 'Wrong PDS variant'
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
if {![file isdirectory axi_control_board_netlist_work]} {vlib axi_control_board_netlist_work}
vmap axi_control_board_netlist_work axi_control_board_netlist_work
vlog -quiet -sv -work axi_control_board_netlist_work {*}$models $netlist tb/axi_control_board_netlist_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf axi_control_board_netlist_run.wlf axi_control_board_netlist_work.axi_control_board_netlist_tb
add wave sim:/axi_control_board_netlist_tb/test_pass
add wave sim:/axi_control_board_netlist_tb/boots
add wave sim:/axi_control_board_netlist_tb/clk_50m
add wave sim:/axi_control_board_netlist_tb/key1_n
add wave sim:/axi_control_board_netlist_tb/led
add wave sim:/axi_control_board_netlist_tb/uart_tx
run -all
if {[examine -radix unsigned sim:/axi_control_board_netlist_tb/test_pass] != 1} {
    error "AXI board netlist stopped without PASS"
}
echo "AXI control board netlist test_pass=1"
catch {wave zoom full}
