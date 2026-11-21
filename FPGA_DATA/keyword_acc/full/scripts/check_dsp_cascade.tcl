# 检查运行时可能选择级联输入、同时却把级联引脚接零的乘法器。
proc kwt_pin_drivers {pin} {
    set nets [get_nets -segments -quiet -of_objects $pin]
    if {![llength $nets]} { return {} }
    return [get_pins -quiet -leaf -of_objects $nets -filter {DIRECTION == OUT}]
}

proc kwt_pin_digit {pin} {
    global kwt_logic_cache
    set local_net [get_nets -quiet -of_objects $pin]
    if {![llength $local_net]} { return ? }
    set key [get_property NAME $local_net]
    if {[info exists kwt_logic_cache($key)]} { return $kwt_logic_cache($key) }

    set drivers [kwt_pin_drivers $pin]
    if {![llength $drivers]} { return ? }
    set cells [get_cells -quiet -of_objects $drivers]
    if {![llength $cells]} { return ? }
    set kinds [lsort -unique [get_property REF_NAME $cells]]
    set value ?
    if {$kinds eq "GND"} { set value 0 }
    if {$kinds eq "VCC"} { set value 1 }
    set kwt_logic_cache($key) $value
    return $value
}

proc kwt_cascade_candidates {report_path} {
    global kwt_logic_cache
    array unset kwt_logic_cache
    set handle [open $report_path w]
    puts $handle "cell,location,opmode5,opmode4,pcin_ground_bits,lower_site_occupant"
    set dsps [get_cells -hier -quiet -filter {REF_NAME == DSP48E2}]
    set unsafe 0
    set lower_busy 0
    foreach cell $dsps {
        set op5 [get_pins -quiet -of_objects $cell -filter {REF_PIN_NAME == "OPMODE[5]"}]
        set op4 [get_pins -quiet -of_objects $cell -filter {REF_PIN_NAME == "OPMODE[4]"}]
        set bit5 [kwt_pin_digit $op5]
        set bit4 [kwt_pin_digit $op4]
        if {$bit5 eq "1" || $bit4 eq "0" || ($bit5 ne "?" && $bit4 ne "?")} { continue }

        set tied 0
        foreach pcin [get_pins -quiet -of_objects $cell -filter {REF_PIN_NAME =~ "PCIN*"}] {
            if {[kwt_pin_digit $pcin] eq "0"} { incr tied }
        }
        if {!$tied} { continue }
        set location [get_property LOC $cell]
        set occupied {}
        if {[regexp {^(DSP48E2_X[0-9]+Y)([0-9]+)$} $location -> column y] && $y > 0} {
            set below [get_sites -quiet "${column}[expr {$y - 1}]"]
            if {[llength $below]} {
                set occupants [get_cells -quiet -of_objects $below]
                if {[llength $occupants]} {
                    set occupied [join [get_property NAME $occupants] "|"]
                    incr lower_busy
                }
            }
        }
        incr unsafe
        puts $handle "[get_property NAME $cell],$location,$bit5,$bit4,$tied,$occupied"
    }
    close $handle
    puts "KWTDSP_BLOCKS=[llength $dsps] PCIN_DYNAMIC_GND=$unsafe LOWER_SITE_OCCUPIED=$lower_busy"
}
