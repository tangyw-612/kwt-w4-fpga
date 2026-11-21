# 先装入带探针的全核，再依次送入两条录音对应的完整数据。
set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir hardware.tcl]
set out [file join $root build $mode]
set ila [get_hw_ilas -of_objects $device]
if {[llength $ila] != 1} { error "预期一个首层 K 探针核: $ila" }

set trigger_probes 0
set manifest [open [file join $out probe_map.tsv] w]
foreach probe [get_hw_probes -of_objects $ila] {
    set map [get_property MAP $probe]
    puts $manifest "$map\t[get_property NAME $probe]"
    if {[regexp {^probe[012](\[|$)} $map]} {
        set_property TRIGGER_COMPARE_VALUE {eq1'b1} $probe
        incr trigger_probes
    }
}
close $manifest
if {$trigger_probes != 3} { error "激活读取的触发信号数量不符: $trigger_probes" }
set_property CONTROL.TRIGGER_CONDITION AND $ila
set_property CONTROL.TRIGGER_POSITION 8 $ila
foreach sample {250 100} {
    run_hw_ila $ila
    puts [exec [lindex $argv 1] -E [file join $root host first_k_trace.py] capture [lindex $argv 2] $sample $out]
    wait_on_hw_ila -timeout 1 $ila
    set capture [upload_hw_ila_data $ila]
    write_hw_ila_data -force -csv_file [file join $out sample_$sample.csv] $capture
    puts "FIRST_K_CAPTURED sample_$sample"
}
