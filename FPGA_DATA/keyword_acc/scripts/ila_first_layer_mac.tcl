# 用 MAC 输出标签触发，保留两行相同列的运算结果。
source [file join [file dirname [info script]] ila_trace.tcl]
set core {g_full.u_demo/u_encoder/u_core}
set left [format {%s/g_mac[0].u_mac} $core]
set right [format {%s/g_mac[1].u_mac} $core]
set probes [list [trace_pin_nets $left out_valid 1] \
    [trace_register_bus $core {o_dest_reg[4]} 4] \
    [trace_register_bus $core {o_col_reg[4]} 8] \
    [trace_pin_nets $right out_valid 1] \
    [trace_pin_nets $left out_data 32] \
    [trace_pin_nets $right out_data 32]]
set rows {}
# 调度按双行递增，标签最低位在综合时被折叠为常量。
for {set bit 1} {$bit < 7} {incr bit} {
    lappend rows {*}[trace_pin_nets [format {%s/o_row_reg[4][%d]} $core $bit] Q 1]
}
lappend probes $rows
trace_ila ila_first_layer_mac [trace_pin_nets $left clk 1] 3 $probes
