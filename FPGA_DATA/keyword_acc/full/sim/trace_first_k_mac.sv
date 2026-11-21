`timescale 1ns/1ps

module trace_first_k_mac (
    input wire clk, rst_n,
    input wire rd, row_pair, col_pair,
    input wire in_valid, in_first, in_last, in_pair,
    input wire [31:0] a_even, a_odd,
    input wire [16:0] b_even, b_odd,
    input wire accum_valid, scale_valid, drain_valid,
    input wire [43:0] accumulator, scale_acc,
    input wire [11:0] scale
);
    int cycle = -1;

    // 两次实板抓取与仿真均以首个双行双列读请求对齐。
    always @(posedge clk) if (rst_n) begin
        if (cycle < 0 && rd && row_pair && col_pair) cycle = 0;
        if (cycle >= 0 && cycle < 128) begin
            $display("KMTRACE %0d %0d %0d %0d %0d %0d %0d %0d %08h %08h %05h %05h %0d %0d %0d %011h %011h %03h",
                     cycle, rd, row_pair, col_pair, in_valid, in_first, in_last, in_pair,
                     a_even, a_odd, {b_even[16], b_even}, {b_odd[16], b_odd},
                     accum_valid, scale_valid, drain_valid, accumulator, scale_acc, scale);
            cycle++;
        end
    end
endmodule

bind ac_enc trace_first_k_mac u_first_k_mac_trace (
    .clk(clk), .rst_n(rst_n), .rd(x_rd), .row_pair(x_pair_rd), .col_pair(x_col_pair_rd),
    .in_valid(g_mac[1].use_input), .in_first(mac_in_first), .in_last(mac_in_last), .in_pair(s1_ffn_pair),
    .a_even(mac_in_a[1]), .a_odd(mac_in_a_odd[1]),
    .b_even(g_mac[1].u_mac.g_lane[0].bj), .b_odd(g_mac[1].u_mac.g_lane[0].b_odd),
    .accum_valid(g_mac[1].u_mac.s2_v), .scale_valid(g_mac[1].u_mac.scale_valid),
    .drain_valid(g_mac[1].use_drain), .accumulator(g_mac[1].u_mac.acc[0]),
    .scale_acc(g_mac[1].u_mac.scale_acc[43:0]), .scale(g_mac[1].u_mac.channel_scale[11:0])
);
