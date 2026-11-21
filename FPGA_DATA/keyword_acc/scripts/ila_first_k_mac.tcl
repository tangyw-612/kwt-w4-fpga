# 两个探针版共用第一个激活读触发。分开保存以适配剩余块存储资源。
source [file join [file dirname [info script]] ila_trace.tcl]
set core {g_full.u_demo/u_encoder/u_core}
set ram $core/u_x
set mac [format {%s/g_mac[1].u_mac} $core]
set probes {}
foreach signal {rd pair_rd col_pair_rd} {
    lappend probes [trace_pin_nets $ram $signal 1]
}

if {$capture eq "first_k_operands"} {
    foreach {pin width} {in_valid 1 in_first 1 in_last 1 in_pair 1 in_a 32 in_a_odd 32} {
        lappend probes [trace_pin_nets $mac $pin $width]
    }
    # 直接取两个 DSP 乘法器的 18 位 B 端，记录实际参与运算的符号位。
    foreach term {even odd} {
        set dsp [format {%s/g_lane[0].u_%s_low/u_product} $mac $term]
        lappend probes [trace_pin_nets $dsp B 18]
    }
} else {
    foreach reg {s2_v_reg scale_valid_reg} {
        lappend probes [trace_pin_nets $mac/$reg Q 1]
    }
    lappend probes [trace_pin_nets $mac dr_valid 1]
    lappend probes [trace_register_bus $mac {g_lane[0].acc_reg[0]} 44]
    lappend probes [trace_register_bus $mac scale_acc_reg 44]
    lappend probes [trace_register_bus $mac channel_scale_reg 12]
}

trace_ila ila_first_k_mac [trace_pin_nets $ram clk 1] 3 $probes
