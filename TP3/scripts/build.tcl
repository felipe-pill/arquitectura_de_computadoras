# Non-project Vivado build for TP3 (Basys 3): synth, place, route, reports,
# bitstream. Run from the repo root with .\build.bat TP3, or directly:
#   vivado -mode batch -source TP3/scripts/build.tcl
# Optional "name value" pairs override basys3_top parameters, e.g.
#   .\build.bat TP3 MMCM_OUT_DIV 10
#   vivado -mode batch -source TP3/scripts/build.tcl -tclargs MMCM_OUT_DIV 10
# Output: build/TP3/vivado/ (reports, checkpoints, basys3_top.bit).
# Stops before the bitstream if setup or hold timing is not met.

set part xc7a35tcpg236-1
set top  basys3_top
set tp   [file normalize [file join [file dirname [info script]] ..]]
set out  [file normalize [file join $tp .. build TP3 vivado]]
file mkdir $out

set generics {}
foreach {name value} $argv {
  lappend generics -generic $name=$value
}

read_verilog [glob [file join $tp src *.v]]
read_xdc     [file join $tp constrs basys3.xdc]

synth_design -top $top -part $part {*}$generics
write_checkpoint -force [file join $out post_synth.dcp]
report_utilization -file [file join $out utilization_synth.rpt]

opt_design
place_design
route_design
write_checkpoint -force [file join $out post_route.dcp]

report_timing_summary -max_paths 10 -report_unconstrained \
  -file [file join $out timing_summary.rpt]
report_timing -setup -max_paths 10 -nworst 1 -path_type full -input_pins \
  -file [file join $out timing_paths.rpt]
report_utilization -file [file join $out utilization.rpt]
report_utilization -hierarchical -file [file join $out utilization_hier.rpt]
report_clock_utilization -file [file join $out clock_utilization.rpt]
report_drc -file [file join $out drc.rpt]

set wns [get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]]
set whs [get_property SLACK [get_timing_paths -hold  -max_paths 1 -nworst 1]]
puts "=== WNS (setup) = $wns ns, WHS (hold) = $whs ns ==="
if {$wns < 0 || $whs < 0} {
  error "TIMING FAILED - see [file join $out timing_summary.rpt]"
}
puts "=== TIMING MET ==="

write_bitstream -force [file join $out $top.bit]
puts "=== BITSTREAM: [file join $out $top.bit] ==="
