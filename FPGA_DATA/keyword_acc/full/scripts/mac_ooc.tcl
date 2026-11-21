# 从既有布线检查点检查物理级联，或独立综合乘加阵列看映射。
set kwt_full_root [file normalize [file join [file dirname [info script]] ..]]
source [file join $kwt_full_root scripts check_dsp_cascade.tcl]
set profile [lindex $argv 0]
set out [file join $kwt_full_root build mac_$profile]
file mkdir $out
set_param general.maxThreads 1

if {$profile eq "routed"} {
    open_checkpoint [file normalize [lindex $argv 1]]
} elseif {$profile in {split_bram split_bram_pv split_bram_pv_signed split_bram_pv_signed_b16 split_bram_pv_signed_b4}} {
    set_part xczu2cg-sfvc784-1-e
    set source_dir [file join $kwt_full_root build generated_$profile]
    set synth_defines {}
    if {[string match split_bram_pv_signed* $profile]} {
        read_verilog -sv [file join $source_dir w4_dsp_mul27x17.sv]
        set synth_defines {-verilog_define W4_NATIVE_DSP}
    }
    read_verilog -sv [file join $source_dir arch_c_mac_array.sv]
    synth_design -top arch_c_mac_array -part xczu2cg-sfvc784-1-e -mode out_of_context \
        -no_timing_driven -flatten_hierarchy none {*}$synth_defines
    report_utilization -file [file join $out utilization.rpt]
    if {[string match split_bram_pv_signed* $profile]} {
        write_checkpoint -force [file join $out arch_c_mac_array.dcp]
        write_verilog -force -mode funcsim [file join $out mac_synth.v]
    }
} else {
    error "乘加核映射名称错误 $profile"
}
kwt_cascade_candidates [file join $out cascade.csv]
