# Optional FUNCTIONAL netlist check; no SDF and no hardware download.
onerror {quit -code 1 -f}
catch {quit -sim}
set netlist build/pds_fetch_handshake/synthesize/board_top_syn.vm
if {![file exists $netlist]} {error "Run build_pds_board.bat --firmware uart_rx_echo --variant fetch_handshake first"}
set pds_root D:/pango/PDS_2022.2-SP6.4
if {[info exists env(PDS_HOME)]} {
    set pds_root $env(PDS_HOME)
} elseif {[info exists env(PDS_SHELL)]} {
    set pds_root [file dirname [file dirname $env(PDS_SHELL)]]
}
set models [glob [file join $pds_root arch vendor pango verilog simulation *.v]]
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory fetch_handshake_netlist_work]} {vlib fetch_handshake_netlist_work}
vmap fetch_handshake_netlist_work fetch_handshake_netlist_work
vlog -quiet -sv -work fetch_handshake_netlist_work {*}$models $netlist tb/uart_rx_netlist_tb.v
vsim -voptargs="+acc" -onfinish stop -wlf fetch_handshake_netlist_run.wlf fetch_handshake_netlist_work.uart_rx_netlist_tb
run -all
if {[examine -radix unsigned sim:/uart_rx_netlist_tb/test_pass] != 1} {
    error "UART RX netlist check stopped without PASS"
}
