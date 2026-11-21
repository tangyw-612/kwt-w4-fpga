# 复用全核独立综合的检查点，板端外壳单独综合后再做整体布局布线。
set root [file dirname [file dirname [file normalize [info script]]]]
set checkpoint [file normalize [lindex $argv 0]]
if {![file isfile $checkpoint]} { error "Missing full encoder DCP: $checkpoint" }
set profile [lindex $argv 1]
if {$profile eq ""} { set profile full }
if {![regexp {^full(_[a-z0-9]+)*$} $profile]} { error "Invalid full encoder profile: $profile" }
set out [file join $root build $profile]
file mkdir $out
set_param general.maxThreads 4

foreach file {board_clock.sv an970_raster.sv board_key.sv uart_byte.sv lcd_font.sv rover_motion.sv rover_scene.sv keyword_acc_top.sv encoder_uart_demo.sv} {
    read_verilog -sv [file join $root rtl $file]
}
read_verilog [file join $root full rtl w4_full_stream_stub.v]
set capture [lindex $argv 2]
set live [expr {$capture eq "live" || [lindex $argv 3] eq "live"}]
set no_display [expr {$capture eq "live" && [lindex $argv 3] eq "no_display"}]
set reference [lindex $argv 4]
if {$reference ne "" && (![file isfile $reference] || !$no_display)} {
    error "Invalid incremental checkpoint for the display-off comparison: $reference"
}
if {$capture eq "live"} { set capture {} }
set generics [list FULL_ENCODER=1]
set options [list -max_dsp 0]
if {$live} {
    foreach file {keyword_live_uart.sv w4_cls_head.sv an970_competition_backdrop.sv an970_competition_text.sv an970_competition_detail.sv an970_keyword_scene.sv} {
        read_verilog -sv [file join $root rtl $file]
    }
    lappend generics LIVE_KEYWORDS=1
    if {$no_display} { lappend generics AN970_ENABLE=0 }
    set options {}
    set working [pwd]
    cd [file join $root data]
}
synth_design -top keyword_acc_top -part xczu2cg-sfvc784-1-e -flatten_hierarchy none {*}$options -generic $generics
if {$live} { cd $working }
set cell [get_cells -hier -filter {REF_NAME == w4_full_stream}]
if {[llength $cell] != 1} { error "Expected one W4 encoder black box: $cell" }
read_checkpoint -cell $cell $checkpoint
# 清理独立综合时的核端时钟约束，板级时钟由差分晶振和 MMCM 重新建立。
reset_timing
read_xdc [file join $root constraints axu2cg_e_an970.xdc]
if {!$no_display} { read_xdc [file join $root constraints an970_output_timing.xdc] }
report_utilization -file [file join $out synth_utilization.rpt]

if {$capture eq "first_k"} {
    source [file join $root scripts ila_first_k.tcl]
} elseif {$capture in {first_k_operands first_k_accum}} {
    source [file join $root scripts ila_first_k_mac.tcl]
} elseif {$capture eq "first_layer_mac"} {
    source [file join $root scripts ila_first_layer_mac.tcl]
} elseif {$capture ne ""} {
    error "Unknown capture: $capture"
}
opt_design
if {$reference ne ""} { read_checkpoint -incremental $reference }
place_design
route_design
if {$reference ne ""} { report_incremental_reuse -file [file join $out route_incremental_reuse.rpt] }
report_utilization -file [file join $out route_utilization.rpt]
report_timing_summary -report_unconstrained -file [file join $out route_timing.rpt]
report_drc -file [file join $out route_drc.rpt]
write_checkpoint -force [file join $out keyword_acc_full_routed.dcp]
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts "ROUTE_SLACK setup=$wns hold=$whs"
if {$wns < 0 || $whs < 0} { error "Timing failed, bitstream withheld" }
if {$capture ne ""} { write_debug_probes -force [file join $out keyword_acc_full.ltx] }
write_bitstream -force [file join $out keyword_acc_full.bit]
puts "BITSTREAM_READY [file join $out keyword_acc_full.bit]"
