# 单独综合激活存储，并导出可做逐地址检查的功能网表。
set base [file normalize [file join [file dirname [info script]] ..]]
set profile [file join $base build generated_split_bram_pv]
set out [file join $base build activation_ooc]
file mkdir $out
set_param general.maxThreads 1
set_part xczu2cg-sfvc784-1-e
read_verilog -sv [list [file join $profile ramsp_fpga.sv] [file join $profile ac_pair_x.sv]]
synth_design -top ac_pair_x -part xczu2cg-sfvc784-1-e -mode out_of_context -flatten_hierarchy none
report_utilization -file [file join $out utilization.rpt]
write_verilog -force -mode funcsim [file join $out ac_pair_x_net.v]
