set root [file dirname [file dirname [file normalize [info script]]]]
set mode [lindex $argv 0]
set action [lindex $argv 1]
if {$mode ni {mac mac_uart mac_uart_an970 bars bars_steady full}} { error "Usage: build.tcl -tclargs mac|mac_uart|mac_uart_an970|bars|bars_steady|full ?project|synth|bit?" }
if {$action eq ""} { set action bit }
if {$action ni {project synth bit}} { error "Unknown build action $action" }

set part xczu2cg-sfvc784-1-e
set out [file join $root build $mode]
file mkdir $out
create_project -force keyword_acc_$mode $out -part $part
set common {board_clock.sv an970_raster.sv board_key.sv uart_byte.sv lcd_font.sv rover_motion.sv rover_scene.sv keyword_acc_top.sv}
foreach file $common { add_files -norecurse [file join $root rtl $file] }

if {$mode in {mac mac_uart mac_uart_an970}} {
    foreach file {w4_projection_pair.sv w4_mac_demo.sv mac_demo_control.sv} { add_files -norecurse [file join $root rtl $file] }
    foreach file {mac_vectors.mem mac_expected.mem} { add_files -norecurse [file join $root data $file] }
}
if {$mode in {mac mac_uart mac_uart_an970}} {
    add_files -norecurse [file join $root rtl mac_uart_frame.sv]
}
if {$mode eq "mac_uart_an970"} {
    foreach file {an970_link_scene.sv an970_link_art.sv} { add_files -norecurse [file join $root rtl $file] }
    foreach file {an970_logo.mem an970_palette.mem an970_labels.mem an970_waves.mem} {
        add_files -norecurse [file join $root data $file]
    }
}
if {$mode eq "mac"} {
    create_ip -name vio -vendor xilinx.com -library ip -module_name mac_board_vio
    set_property -dict [list CONFIG.C_NUM_PROBE_IN 6 CONFIG.C_NUM_PROBE_OUT 1 \
        CONFIG.C_PROBE_IN0_WIDTH 8 CONFIG.C_PROBE_IN1_WIDTH 32 CONFIG.C_PROBE_IN2_WIDTH 32 \
        CONFIG.C_PROBE_IN3_WIDTH 32 CONFIG.C_PROBE_IN4_WIDTH 27 CONFIG.C_PROBE_IN5_WIDTH 6 \
        CONFIG.C_PROBE_OUT0_WIDTH 3] [get_ips mac_board_vio]
    generate_target all [get_ips mac_board_vio]
} elseif {$mode eq "full"} {
    set kwt_source_dir generated_split_bram_pv_signed
    source [file join $root full scripts sources.tcl]
    add_files -norecurse $kwt_sources
    add_files -norecurse [file join $root rtl encoder_uart_demo.sv]
    set_property verilog_define W4_NATIVE_DSP [get_filesets sources_1]
}
add_files -fileset constrs_1 -norecurse [file join $root constraints axu2cg_e_an970.xdc]
add_files -fileset constrs_1 -norecurse [file join $root constraints an970_output_timing.xdc]
set_property top keyword_acc_top [get_filesets sources_1]
set_property generic [list COLOR_BARS=[expr {$mode in {bars bars_steady}}] FULL_ENCODER=[expr {$mode eq "full"}] \
    JTAG_DIAGNOSTICS=[expr {$mode eq "mac"}] STEADY_BACKLIGHT=[expr {$mode eq "bars_steady"}] \
    FRAMED_MAC_UART=[expr {$mode in {mac_uart mac_uart_an970}}] AN970_LINK_UI=[expr {$mode eq "mac_uart_an970"}]] [get_filesets sources_1]
update_compile_order -fileset sources_1
if {$action eq "project"} { return }

launch_runs synth_1 -jobs 1
wait_on_run synth_1
if {![string match "*Complete*" [get_property STATUS [get_runs synth_1]]]} { error "Synthesis failed" }
open_run synth_1
report_utilization -file [file join $out synth_utilization.rpt]
report_utilization -hierarchical -file [file join $out synth_hierarchy.rpt]
if {$action eq "synth"} { return }
close_design

launch_runs impl_1 -to_step route_design -jobs 1
wait_on_run impl_1
if {![string match "*Complete*" [get_property STATUS [get_runs impl_1]]]} { error "Implementation failed" }
open_run impl_1
report_utilization -file [file join $out route_utilization.rpt]
report_timing_summary -report_unconstrained -file [file join $out route_timing.rpt]
report_drc -file [file join $out route_drc.rpt]
set setup [get_timing_paths -quiet -delay_type max -max_paths 1]
set hold [get_timing_paths -quiet -delay_type min -max_paths 1]
if {[llength $setup] == 0 || [llength $hold] == 0} { error "No timed paths" }
set wns [get_property SLACK $setup]
set whs [get_property SLACK $hold]
puts "ROUTE_SLACK setup=$wns hold=$whs"
if {$wns < 0 || $whs < 0} { error "Timing failed, bitstream withheld" }
if {$mode eq "mac"} { write_debug_probes -force [file join $out keyword_acc_mac.ltx] }
write_bitstream -force [file join $out keyword_acc_$mode.bit]
puts "BITSTREAM_READY [file join $out keyword_acc_$mode.bit]"
