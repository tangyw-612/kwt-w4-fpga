# 对 AXU2CG-E 器件评估流接口编码器的资源，不配置任何板端引脚。
set kwt_map [lindex $argv 0]
if {$kwt_map in {split split_bram split_bram_pv split_bram_pv_signed split_bram_pv_signed_b16 split_bram_pv_signed_b4 split_bram_pv_signed_b4_gelu}} {
    set kwt_source_dir generated_$kwt_map
} elseif {$kwt_map ne "" && $kwt_map ne "lut"} {
    error "未知乘法映射 $kwt_map"
}
source [file join [file dirname [info script]] sources.tcl]
set kwt_ooc_dir [expr {$kwt_map eq "" || $kwt_map eq "lut" ? "ooc" : "ooc_$kwt_map"}]
set kwt_build [file join $kwt_full_root build $kwt_ooc_dir]
file mkdir $kwt_build
set_part xczu2cg-sfvc784-1-e
set_param general.maxThreads 2
read_verilog -sv $kwt_sources
set kwt_synth_defines {}
if {[string match split_bram_pv_signed* $kwt_map]} { set kwt_synth_defines {-verilog_define W4_NATIVE_DSP} }
read_xdc [file join $kwt_full_root scripts kernel.xdc]
synth_design -top w4_full_stream -part xczu2cg-sfvc784-1-e -mode out_of_context \
    -no_timing_driven -flatten_hierarchy none {*}$kwt_synth_defines
report_utilization -file [file join $kwt_build utilization.rpt]
report_utilization -hierarchical -file [file join $kwt_build utilization_hier.rpt]
report_timing_summary -file [file join $kwt_build timing_synth.rpt]
write_checkpoint -force [file join $kwt_build w4_full_stream.dcp]
