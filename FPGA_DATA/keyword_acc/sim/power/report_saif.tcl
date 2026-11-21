# 每种工况从同一份最终布线检查点开始，防止活动数据串用。
set profile [file normalize [lindex $argv 0]]
set mode [lindex $argv 1]
if {$mode ni {standby w4_active}} { error "未知功耗工况 $mode" }
set out [file join $profile power_saif]
set_param general.maxThreads 4
open_checkpoint [file join $profile keyword_acc_full_routed.dcp]
read_saif -strip_path dut -out_file [file join $out "${mode}_annotation.txt"] \
    [file join $out "${mode}_mapped.saif"]
report_power -file [file join $out "${mode}_power.rpt"]
