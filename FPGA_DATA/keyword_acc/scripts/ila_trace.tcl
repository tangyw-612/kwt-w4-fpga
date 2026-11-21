# 严格按位号连接探针，避免综合名称排序造成位序颠倒。
proc trace_pin_nets {path signal width} {
    set cell [get_cells -hier -filter [format {NAME == "%s"} $path]]
    if {[llength $cell] != 1} { error "找不到探针单元 $path" }
    set pins [get_pins -of_objects $cell]
    set result {}
    for {set bit 0} {$bit < $width} {incr bit} {
        set name [expr {$width == 1 ? $signal : [format {%s[%d]} $signal $bit]}]
        set pin [filter $pins [format {REF_PIN_NAME == "%s"} $name]]
        set net [get_nets -quiet -of_objects $pin]
        if {[llength $net] != 1} { error "探针 $path/$name 的网络数量异常: $net" }
        lappend result $net
    }
    return $result
}

proc trace_register_bus {path base width} {
    set result {}
    for {set bit 0} {$bit < $width} {incr bit} {
        lappend result {*}[trace_pin_nets [format {%s/%s[%d]} $path $base $bit] Q 1]
    }
    return $result
}

proc trace_ila {name clock trigger_count groups} {
    create_debug_core $name ila
    set ila [get_debug_cores $name]
    set_property C_DATA_DEPTH 1024 $ila
    set_property C_INPUT_PIPE_STAGES 1 $ila
    set_property C_ADV_TRIGGER false $ila
    set_property C_EN_STRG_QUAL false $ila
    set clock_port [get_debug_ports $name/clk]
    set_property port_width 1 $clock_port
    connect_debug_port $clock_port $clock
    set index 0
    foreach nets $groups {
        if {$index > 0} { create_debug_port $name probe }
        set port [get_debug_ports $name/probe$index]
        set_property port_width [llength $nets] $port
        set_property PROBE_TYPE [expr {$index < $trigger_count ? "DATA_AND_TRIGGER" : "DATA"}] $port
        connect_debug_port $port $nets
        incr index
    }
}
