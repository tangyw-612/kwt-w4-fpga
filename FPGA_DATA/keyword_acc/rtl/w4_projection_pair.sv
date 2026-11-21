`default_nettype none
module w4_projection_pair (
    input wire clk, rst_n,
    input wire pair_valid, pair_first, pair_last,
    input wire [31:0] activation0, activation1,
    input wire [15:0] codes,
    input wire drain_valid, drain_lane,
    output logic output_valid,
    output logic [31:0] output_value
);
    logic multiply_valid, multiply_first, multiply_last;
    logic read_valid;
    logic [31:0] read_value;
    logic signed [35:0] products0 [0:1], products1 [0:1];
    logic signed [43:0] sums [0:1], shadow [0:1];

    // 有符号码的最高位权值是 -8，其他三位的权值依次为 1、2、4。
    function automatic signed [35:0] signed_product(input [31:0] activation, input [3:0] code);
        logic signed [35:0] value;
        value = {{4{activation[31]}}, activation};
        return (code[0] ? value : 36'sd0)
             + (code[1] ? (value <<< 1) : 36'sd0)
             + (code[2] ? (value <<< 2) : 36'sd0)
             - (code[3] ? (value <<< 3) : 36'sd0);
    endfunction

    // 两个输出通道分别保留 44 位部分和，每次归约接收相邻两项。
    for (genvar lane = 0; lane < 2; lane++) begin : g_lane
        wire signed [43:0] first_term = {{8{products0[lane][35]}}, products0[lane]};
        wire signed [43:0] second_term = {{8{products1[lane][35]}}, products1[lane]};
        wire signed [43:0] next_sum = (multiply_first ? 44'sd0 : sums[lane]) + first_term + second_term;
        always_ff @(posedge clk) begin
            if (pair_valid) begin
                products0[lane] <= signed_product(activation0, codes[4*lane +: 4]);
                products1[lane] <= signed_product(activation1, codes[8+4*lane +: 4]);
            end
            if (multiply_valid) begin
                sums[lane] <= next_sum;
                if (multiply_last) shadow[lane] <= next_sum;
            end
        end
    end

    wire [43:0] selected = shadow[drain_lane];
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            multiply_valid <= 0;
            multiply_first <= 0;
            multiply_last <= 0;
            read_valid <= 0;
            read_value <= 0;
            output_valid <= 0;
            output_value <= 0;
        end else begin
            multiply_valid <= pair_valid;
            multiply_first <= pair_first;
            multiply_last <= pair_last;
            read_valid <= drain_valid;
            if (drain_valid) begin
                if (selected[43:31] == {13{selected[31]}}) read_value <= selected[31:0];
                else read_value <= selected[43] ? 32'h80000000 : 32'h7fffffff;
            end
            output_valid <= read_valid;
            if (read_valid) output_value <= read_value;
        end
    end
endmodule
`default_nettype wire
