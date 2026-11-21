`timescale 1ns/1ps

module trace_first_layer_mac (
    input wire clk, rst_n, first_layer,
    input wire [1:0] valid,
    input wire [3:0] dest,
    input wire [6:0] row,
    input wire [7:0] col,
    input wire signed [31:0] data [2],
    input wire gelu_valid, ffn2_valid,
    input wire [7:0] gelu_tag,
    input wire [15:0] gelu_data,
    input wire [31:0] activation_even, activation_odd,
    input wire [3:0] weight_even, weight_odd
);
    int cycle = 0;
    // 用同一组流水线标签对照 ILA 和 RTL 的两个物理 MAC。
    always @(posedge clk) if (rst_n) begin
        cycle++;
        if (first_layer && row < 8) for (int side = 0; side < 2; side++) begin
            if (valid[side]) begin
                $display("STAGEMAC %0d %0d %0d %0d %0d %08h", cycle, dest, row, col, side, data[side]);
            end
        end
        if (first_layer && gelu_valid)
            $display("GELUTRACE %0d %0d %04h", cycle, gelu_tag, gelu_data);
        if (first_layer && ffn2_valid)
            $display("F2IN %0d %05h %05h %h %h", cycle,
                     {activation_even[31], activation_even[15:0]},
                     {activation_odd[31], activation_odd[15:0]}, weight_even, weight_odd);
    end
endmodule

bind ac_enc trace_first_layer_mac u_first_layer_mac_trace (
    .clk(clk), .rst_n(rst_n), .first_layer(cur_layer == 0),
    .valid(mac_out_valid), .dest(out_dest), .row(out_row), .col(out_col), .data(mac_out_data),
    .gelu_valid(g_out_valid[0]), .gelu_tag(g_out_col[0]), .gelu_data(g_out_data[0]),
    .ffn2_valid(mac_in_valid && s1_asrc[2]), .activation_even(mac_in_a[0]), .activation_odd(mac_in_a_odd[0]),
    .weight_even(mac_in_b[3:0]), .weight_odd(mac_in_b_odd[3:0])
);
