#include "Vtb_kwt_power.h"
#include "verilated.h"
#include "verilated_saif_c.h"

#include <cstdint>
#include <iostream>

double sc_time_stamp() {
    // 模拟时间由 VerilatedContext 管理。
    return 0;
}

int main(int argc, char** argv) {
    if (argc < 3) {
        std::cerr << "Usage: kwt_power OUTPUT.saif +inputs=DIR [+idle]\n";
        return 2;
    }
    VerilatedContext context;
    context.commandArgs(argc - 1, argv + 1);
    context.traceEverOn(true);
    Vtb_kwt_power model{&context};
    VerilatedSaifC trace;
    model.trace(&trace, 20);
    std::uint64_t trace_ps = 0;
    std::uint64_t prior_ps = 0;
    bool enabled = false;
    bool started = false;
    while (!context.gotFinish()) {
        model.eval();
        const auto now_ps = context.time();
        const bool enabled_now = model.capture;
        if (enabled) {
            trace_ps += now_ps - prior_ps;
            trace.dump(trace_ps);
        } else if (enabled_now) {
            // 把所选活跃片段的时间拼接起来，等待阶段不进入活动统计。
            if (!started) {
                trace.open(argv[1]);
                started = true;
            } else {
                ++trace_ps;
            }
            trace.dump(trace_ps);
        }
        enabled = enabled_now;
        prior_ps = now_ps;
        if (!model.eventsPending()) break;
        context.time(model.nextTimeSlot());
    }
    model.final();
    if (!started || !context.gotFinish()) return 1;
    trace.close();
    std::cout << "POWER_SAIF_DURATION_PS " << trace_ps << '\n';
    return 0;
}
