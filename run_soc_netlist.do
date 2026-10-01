# Optional FUNCTIONAL netlist check; no SDF and no hardware download.
onerror {quit -code 1 -f}
catch {quit -sim}
set netlist build/pds_soc/synthesize/board_top_syn.vm
if {![file exists $netlist]} {error "Run build_pds_board.bat --firmware uart_rx_echo --variant soc first"}
set pds_root D:/pango/PDS_2022.2-SP6.4
if {[info exists env(PDS_HOME)]} {
    set pds_root $env(PDS_HOME)
} elseif {[info exists env(PDS_SHELL)]} {
    set pds_root [file dirname [file dirname $env(PDS_SHELL)]]
}
set models [glob [file join $pds_root arch vendor pango verilog simulation *.v]]
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory soc_netlist_work]} {vlib soc_netlist_work}
vmap soc_netlist_work soc_netlist_work
vlog -quiet -sv -work soc_netlist_work {*}$models $netlist tb/uart_rx_netlist_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf soc_netlist_run.wlf soc_netlist_work.uart_rx_netlist_tb
run -all
if {[examine -radix unsigned sim:/uart_rx_netlist_tb/test_pass] != 1} {
    error "UART RX netlist check stopped without PASS"
}
