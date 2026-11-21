# 分段执行现有快照，避免长时间只能看到 run -all。
proc gate_time_ps {time} {
    lassign $time value unit
    set factor [dict get {fs 0.001 ps 1 ns 1000 us 1000000 ms 1000000000 s 1000000000000} $unit]
    return [expr {round($value * $factor)}]
}

set previous [gate_time_ps [current_time]]
for {set batch 0} {$batch < 751} {incr batch} {
    run 200us
    set now [current_time]
    puts "W4_GATE_PROGRESS time=$now"
    set elapsed [gate_time_ps $now]
    if {$elapsed - $previous < 200000000} { break }
    set previous $elapsed
}
quit
