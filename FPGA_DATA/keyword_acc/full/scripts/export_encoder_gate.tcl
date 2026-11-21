# 从已综合检查点导出功能网表，用于对比首层激活写回。
set checkpoint [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
if {![file isfile $checkpoint]} { error "检查点不存在：$checkpoint" }
file mkdir $out
set_param general.maxThreads 2
open_checkpoint $checkpoint
write_verilog -force -mode funcsim [file join $out encoder_gate.v]
