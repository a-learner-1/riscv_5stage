# Optional post-synthesis FUNCTIONAL check; not an SDF timing simulation.
# Run build_pds_board.bat first. Normal first use only needs run_board.do.
onerror {quit -code 1 -f}
catch {quit -sim}
set netlist build/pds_board/synthesize/board_top_syn.vm
if {![file exists $netlist]} {error "Missing synthesized netlist: build the PDS project first"}
set pds_root D:/pango/PDS_2022.2-SP6.4
if {[info exists env(PDS_HOME)]} {
    set pds_root $env(PDS_HOME)
} elseif {[info exists env(PDS_SHELL)]} {
    set pds_root [file dirname [file dirname $env(PDS_SHELL)]]
}
set models [glob [file join $pds_root arch vendor pango verilog simulation *.v]]
if {![file exists modelsim.ini]} {vmap -c}
if {![file isdirectory board_netlist_work]} {vlib board_netlist_work}
vmap board_netlist_work board_netlist_work
vlog -quiet -sv -work board_netlist_work {*}$models $netlist tb/board_netlist_tb.v
vsim -onfinish stop -wlf board_netlist_run.wlf board_netlist_work.board_netlist_tb
run -all
