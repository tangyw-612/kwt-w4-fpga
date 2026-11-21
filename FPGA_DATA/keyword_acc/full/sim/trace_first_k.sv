`timescale 1ns/1ps

module trace_first_k (
    input wire clk, rst_n,
    input wire read_enable, pair_rd, col_pair_rd,
    input wire [5:0] col,
    input wire [31:0] activation_even, activation_odd,
    input wire in_valid, out_valid,
    input wire [31:0] value,
    input wire [3:0] dest,
    input wire [6:0] row,
    input wire [7:0] out_col
);
    int cycle = -1;

    // 与 ILA 一样在上升沿取样，读请求后的下一拍才对照 RAM 输出。
    always @(posedge clk) if (rst_n) begin
        if (cycle < 0 && read_enable && pair_rd && col_pair_rd) cycle = 0;
        if (cycle >= 0 && cycle < 1024) begin
            $display("KTRACE %0d %0d %0d %0d %0d %08h %08h %0d %0d %08h %0d %0d %0d",
                     cycle, read_enable, pair_rd, col_pair_rd, col,
                     activation_even, activation_odd, in_valid, out_valid, value, dest, row, out_col);
            cycle++;
        end
    end
endmodule

bind ac_enc trace_first_k u_first_k_trace (
    .clk(clk), .rst_n(rst_n),
    .read_enable(x_rd), .pair_rd(x_pair_rd), .col_pair_rd(x_col_pair_rd),
    .col(x_addr[5:0]), .activation_even(x_q_other), .activation_odd(x_q_other_odd),
    .in_valid(s1_valid && s1_pair_q), .out_valid(mac_out_valid[1]),
    .value(mac_out_data[1]), .dest(out_dest), .row(out_row), .out_col(out_col)
);
