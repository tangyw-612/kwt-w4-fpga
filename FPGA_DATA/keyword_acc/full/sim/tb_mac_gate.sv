`timescale 1ns/1ps

module tb_mac_gate;
    localparam int LANES = 32;
    bit clk = 0, rst_n = 0;
    bit in_valid, in_first, in_last, in_hi, in_pair, in_qk_pair, in_pv_pair;
    logic signed [31:0] in_a, in_a_odd;
    logic [LANES*17-1:0] in_b, in_b_odd;
    wire [LANES*17-1:0] gate_b, gate_b_odd;
    bit projection_low_nibble;
    bit dr_valid, dr_sat16;
    logic [4:0] dr_idx;
    logic signed [63:0] dr_bias;
    logic [15:0] dr_scale;
    logic [5:0] dr_shift;
    wire rtl_valid, gate_valid;
    wire signed [31:0] rtl_data, gate_data;
    int checked = 0;

    always #15 clk = !clk;
    arch_c_mac_array rtl (.out_valid(rtl_valid), .out_data(rtl_data), .*);
    arch_c_mac_array_gate gate (.in_b(gate_b), .in_b_odd(gate_b_odd),
                               .out_valid(gate_valid), .out_data(gate_data), .*);
    for (genvar lane = 0; lane < LANES; lane++) begin : g_weight
        // 模拟实板只送达四位权重码的情况，保留注意力运算的完整输入。
        wire truncate = projection_low_nibble && !in_qk_pair && !in_pv_pair;
        assign gate_b[lane*17 +: 17] = truncate ? {13'b0, in_b[lane*17 +: 4]} : in_b[lane*17 +: 17];
        assign gate_b_odd[lane*17 +: 17] = truncate ? {13'b0, in_b_odd[lane*17 +: 4]} : in_b_odd[lane*17 +: 17];
    end

    function automatic logic signed [31:0] activation(input int mode, term, terms);
        logic [31:0] random_bits;
        random_bits = $urandom;
        case (mode)
            1: return 32'($signed(random_bits[15:0]));
            2: return term == 0 ? 32'h01000000 - 32'(terms - 1) : 32'd1;
            default: return $signed(random_bits);
        endcase
    endfunction

    function automatic logic [16:0] weight(input int mode);
        logic [31:0] random_bits;
        random_bits = $urandom;
        return mode == 0 ? 17'($signed(random_bits[3:0])) : 17'($signed(random_bits[15:0]));
    endfunction

    task automatic exercise(input int mode, terms);
        for (int term = 0; term < terms; term++) begin
            @(negedge clk);
            in_valid = 1;
            in_first = term == 0;
            in_last = term == terms - 1;
            in_pair = 1;
            in_qk_pair = mode == 1;
            in_pv_pair = mode == 2;
            in_a = activation(mode, term, terms);
            in_a_odd = activation(mode, term, terms);
            for (int lane = 0; lane < LANES; lane++) begin
                in_b[lane*17 +: 17] = weight(mode);
                in_b_odd[lane*17 +: 17] = weight(mode);
            end
        end
        @(negedge clk);
        in_valid = 0;
        repeat (4) @(negedge clk);
        for (int lane = 0; lane < LANES; lane++) begin
            dr_valid = 1;
            dr_idx = 5'(lane);
            dr_bias = 64'($signed($urandom));
            dr_scale = lane % 3 == 0 ? 16'd1 : 16'($urandom_range(4095, 2));
            dr_shift = 6'($urandom_range(29, 13));
            dr_sat16 = lane % 4 == 0;
            @(negedge clk);
        end
        dr_valid = 0;
    endtask

    always @(posedge clk) begin
        #1;
        if (rst_n && (rtl_valid !== gate_valid || (rtl_valid && rtl_data !== gate_data)))
            $fatal(1, "乘加功能网表差异 idx=%0d RTL=%h 网表=%h", checked, rtl_data, gate_data);
        if (rst_n && rtl_valid) checked++;
    end

    initial begin
        projection_low_nibble = $test$plusargs("w4_nibble_only");
        repeat (12) @(negedge clk);
        rst_n = 1;
        for (int mode = 0; mode < 3; mode++) begin
            exercise(mode, 1);
            exercise(mode, 64);
            exercise(mode, 99);
            exercise(mode, 256);
        end
        repeat (8) @(negedge clk);
        if (checked != 12 * LANES) $fatal(1, "乘加回读数量错误 %0d", checked);
        $display("W4_GATE_MAC_PASS modes=3 results=%0d", checked);
        $finish;
    end
endmodule
