# 逐个触发首层各算子第一个输出，供同标签对比。
set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir hardware.tcl]
set out [file join $root build $mode]
set ila [get_hw_ilas -of_objects $device]
if {[llength $ila] != 1} { error "预期一个 MAC 输出探针核: $ila" }

set manifest [open [file join $out probe_map.tsv] w]
set triggers {}
foreach probe [get_hw_probes -of_objects $ila] {
    set map [get_property MAP $probe]
    puts $manifest "$map\t[get_property NAME $probe]"
    if {[regexp {^probe([0-2])\[([0-9]+)(?::([0-9]+))?\]$} $map -> port high low]} {
        if {$low eq ""} { set low $high }
        lappend triggers [list $probe $port $low [expr {$high - $low + 1}]]
    }
}
close $manifest
if {[llength $triggers] < 3} { error "MAC 输出触发信号缺失" }
set_property CONTROL.TRIGGER_CONDITION AND $ila
set_property CONTROL.TRIGGER_POSITION 8 $ila
set stages [lrange $argv 3 end]
if {[llength $stages] == 0} { set stages {0 1 2 3 5 6 9 11} }
foreach stage $stages {
    set compare [list 1 $stage 0]
    foreach entry $triggers {
        lassign $entry probe port low width
        set value [expr {([lindex $compare $port] >> $low) & ((1 << $width) - 1)}]
        set_property TRIGGER_COMPARE_VALUE [format {eq%d'h%x} $width $value] $probe
    }
    foreach sample {250 100} {
        set stage_dir [file join $out stage_$stage]
        file mkdir $stage_dir
        run_hw_ila $ila
        puts [exec [lindex $argv 1] -E [file join $root host first_k_trace.py] capture [lindex $argv 2] $sample $stage_dir]
        wait_on_hw_ila -timeout 1 $ila
        set capture [upload_hw_ila_data $ila]
        write_hw_ila_data -force -csv_file [file join $stage_dir sample_$sample.csv] $capture
        puts "FIRST_LAYER_MAC_CAPTURED dest=$stage sample=$sample"
    }
}
