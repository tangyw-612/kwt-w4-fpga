# 此脚本在下载 MAC 位流后运行，校验实际硬件的算术结果和 RGB 数据有效区。
set vios [get_hw_vios -quiet -of_objects $device]
if {[llength $vios] != 1} { error "Expected one VIO, found $vios" }
set vio [lindex $vios 0]

proc probe {vio term} {
    set probes [get_hw_probes -quiet -of_objects $vio -filter "NAME =~ *$term*"]
    if {[llength $probes] != 1} { error "Missing or ambiguous probe $term; available [get_hw_probes -of_objects $vio]" }
    return [lindex $probes 0]
}
proc hexa {object property} {
    set value [get_property $property $object]
    if {[scan $value %x result] != 1} { error "Cannot parse $object $property: $value" }
    return $result
}

set command_probe [probe $vio jtag_command]
set status_probe [probe $vio jtag_status]
set result0_probe [probe $vio value0]
set result1_probe [probe $vio value1]
set cycle_probe [probe $vio cycles]
set video_probe [probe $vio jtag_video]
set rover_probe [probe $vio jtag_position]
set channel [open [file join $root data mac_expected.mem] r]
set expected [split [string trim [read $channel]] "\n"]
close $channel

after 250
refresh_hw_vio $vio
set before [hexa $video_probe INPUT_VALUE]
for {set index 0} {$index < 4} {incr index} {
    set request [expr {$index | ((($index + 1) & 1) << 2)}]
    set_property OUTPUT_VALUE [format %x $request] $command_probe
    commit_hw_vio $command_probe
    after 100
    refresh_hw_vio $vio
    set status [hexa $status_probe INPUT_VALUE]
    set dot0 [hexa $result0_probe INPUT_VALUE]
    set dot1 [hexa $result1_probe INPUT_VALUE]
    set cycles [hexa $cycle_probe INPUT_VALUE]
    set expected_pair [string trim [lindex $expected $index]]
    set rover [hexa $rover_probe INPUT_VALUE]
    set expected_rover [lindex {27 26 18 18} $index]
    if {$status != (0x2d | ($index << 6)) || [format %08x%08x [expr {$dot1 & 0xffffffff}] [expr {$dot0 & 0xffffffff}]] ne $expected_pair || $cycles <= 32 || $cycles >= 128 || $rover != $expected_rover} {
        error "MAC board mismatch index=$index status=$status dot0=$dot0 dot1=$dot1 cycles=$cycles rover=$rover"
    }
    puts "MAC_BOARD_PASS command=[lindex {RIGHT UP LEFT STOP} $index] cycles=$cycles values=$expected_pair position=$rover"
}

set after [hexa $video_probe INPUT_VALUE]
if {($after & 0x7ffff) != 384000 || ($before >> 19) == ($after >> 19)} {
    error "AN970 active pixel count or frame advance failed: $before $after"
}
puts "AN970_BOARD_SCAN_PASS pixels=[expr {$after & 0x7ffff}] frame=[expr {$after >> 19}]"
