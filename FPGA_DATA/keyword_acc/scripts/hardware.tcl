set mode [lindex $argv 0]
set isFull [regexp {^full(_[a-z0-9]+)*$} $mode]
if {$mode ni {probe mac mac_uart mac_uart_an970 bars bars_steady} && !$isFull} { error "Usage: hardware.tcl -tclargs probe|mac|mac_uart|mac_uart_an970|bars|bars_steady|full|full_<profile>" }
set root [file dirname [file dirname [file normalize [info script]]]]
open_hw_manager
connect_hw_server -allow_non_jtag
set targets [get_hw_targets -quiet]
if {[llength $targets] == 0} { error "No JTAG cable detected" }
set matching {}
foreach target $targets {
    catch {set_property PARAM.FREQUENCY 5000000 $target}
    open_hw_target $target
    set devices [get_hw_devices -quiet -filter {PART =~ xczu2*}]
    if {[llength $devices] > 0} {
        set matching $devices
        break
    }
    close_hw_target $target
}
if {[llength $matching] != 1} { error "Expected one XCZU2 on a hardware target, found $matching" }
set device [lindex $matching 0]
puts "JTAG_DEVICE $device [get_property PART $device]"
if {$mode eq "probe"} { return }
set target [expr {$isFull ? "full" : $mode}]
set bitstream [file join $root build $mode keyword_acc_$target.bit]
if {![file isfile $bitstream]} { error "Missing bitstream: $bitstream" }
set_property PROGRAM.FILE $bitstream $device
set probes [file rootname $bitstream].ltx
if {[file isfile $probes]} {
    set_property PROBES.FILE $probes $device
    set_property FULL_PROBES.FILE $probes $device
}
program_hw_devices $device
refresh_hw_device $device
puts "PROGRAMMED $bitstream"
if {$mode eq "mac" && [lindex $argv 1] eq "test"} {
    source [file join $root scripts verify_mac_jtag.tcl]
}
