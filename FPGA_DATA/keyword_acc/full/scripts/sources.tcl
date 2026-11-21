# 与板级工程共用同一份源码顺序。调用前运行 prepare.py。
set kwt_full_root [file normalize [file join [file dirname [info script]] ..]]
if {![info exists kwt_source_dir]} {
    set kwt_source_dir generated
}
set kwt_sources_file [open [file join $kwt_full_root build $kwt_source_dir sources.f] r]
set kwt_sources [split [string trim [read $kwt_sources_file]] "\n"]
close $kwt_sources_file
