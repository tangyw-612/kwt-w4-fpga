# 保留 FFN1 触发通道，只替换已经布线的 ILA 数据通道。
set root [file dirname [file dirname [file normalize [info script]]]]
set baseline [file join $root build full_b4_stages]
set out [file join $root build full_b4_ffn]
file mkdir $out
set_param general.maxThreads 4
open_checkpoint [file join $baseline keyword_acc_full_routed.dcp]
source [file join $root scripts ila_trace.tcl]

set core {g_full.u_demo/u_encoder/u_core}
set gelu [format {%s/g_pair_gelu[0].u_gelu} $core]
set mac [format {%s/g_mac[0].u_mac} $core]
set data {}
foreach {signal width} {out_valid 1 out_tag 8 out_data 16} {
    lappend data {*}[trace_pin_nets $gelu $signal $width]
}
lappend data {*}[trace_pin_nets $mac in_valid 1]
lappend data {*}[trace_pin_nets [format {%s/s1_asrc_reg[2]} $core] Q 1]
foreach signal {in_a in_a_odd} {
    set bits [trace_pin_nets $mac $signal 32]
    lappend data {*}[lrange $bits 0 15] [lindex $bits 31]
}
foreach signal {in_b in_b_odd} {
    lappend data {*}[trace_pin_nets $mac $signal 4]
}

set layout [open [file join $out probe_layout.json] w]
puts $layout {[1,4,8,1,32,32,6]}
close $layout
set pins [get_pins -of_objects [get_cells ila_first_layer_mac]]
set index 0
foreach {port width} {3 1 4 32 5 32 6 6} {
    for {set bit 0} {$bit < $width && $index < [llength $data]} {incr bit} {
        set name [format {probe%d[%d]} $port $bit]
        set pin [filter $pins [format {REF_PIN_NAME == "%s"} $name]]
        if {[llength $pin] != 1} { error "找不到 ILA 端口 $name" }
        disconnect_net -net [get_nets -of_objects $pin] -objects $pin
        connect_net -hierarchical -net [lindex $data $index] -objects $pin
        incr index
    }
}
if {$index != [llength $data]} { error "ILA 数据端口位宽不足" }
puts "REWIRED_ILA_BITS $index"
route_design -preserve
report_route_status -file [file join $out route_status.rpt]
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts "ROUTE_SLACK setup=$wns hold=$whs"
if {$wns < 0 || $whs < 0} { error "探针重接后的时序未通过" }
write_checkpoint -force [file join $out keyword_acc_full_routed.dcp]
file copy -force [file join $baseline keyword_acc_full.ltx] [file join $out keyword_acc_full.ltx]
write_bitstream -force [file join $out keyword_acc_full.bit]
puts "BITSTREAM_READY [file join $out keyword_acc_full.bit]"
