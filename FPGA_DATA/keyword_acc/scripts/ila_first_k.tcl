# 首个双行和双列激活读请求触发。记录第二行的两个读数据及投影结果。
proc first_k_nets {path signal width} {
    set cell [get_cells -hier -filter [format {NAME == "%s"} $path]]
    if {[llength $cell] != 1} { error "找不到探针层次 $path" }
    set nets {}
    for {set bit 0} {$bit < $width} {incr bit} {
        set leaf [expr {$width == 1 ? $signal : [format {%s[%d]} $signal $bit]}]
        set pin [get_pins -of_objects $cell -filter [format {REF_PIN_NAME == "%s"} $leaf]]
        set net [get_nets -of_objects $pin]
        if {[llength $net] != 1} { error "探针 $path/$leaf 的网络数量异常: $net" }
        lappend nets $net
    }
    return $nets
}

set core {g_full.u_demo/u_encoder/u_core}
set ram $core/u_x
set mac [format {%s/g_mac[1].u_mac} $core]
create_debug_core ila_first_k ila
set ila [get_debug_cores ila_first_k]
set_property C_DATA_DEPTH 1024 $ila
set_property C_INPUT_PIPE_STAGES 1 $ila
set_property C_ADV_TRIGGER false $ila
set_property C_EN_STRG_QUAL false $ila
set clk_port [get_debug_ports ila_first_k/clk]
set_property port_width 1 $clk_port
connect_debug_port $clk_port [first_k_nets $ram clk 1]

set index 0
foreach {path signal width probe_type} [list \
    $ram rd 1 DATA_AND_TRIGGER $ram pair_rd 1 DATA_AND_TRIGGER \
    $ram col_pair_rd 1 DATA_AND_TRIGGER $ram addr 6 DATA \
    $ram q_other 32 DATA $ram q_other_odd 32 DATA \
    $mac in_valid 1 DATA $mac out_valid 1 DATA $mac out_data 32 DATA] {
    if {$index > 0} { create_debug_port ila_first_k probe }
    set port [get_debug_ports ila_first_k/probe$index]
    set_property port_width $width $port
    set_property PROBE_TYPE $probe_type $port
    connect_debug_port $port [first_k_nets $path $signal $width]
    incr index
}
