`default_nettype none
module linear_requantize #(
    parameter int ACC_W = 40,
    parameter int OUT_W = 16,
    parameter int SHIFT = 8
) (
    input  logic signed [ACC_W-1:0] value,
    output logic signed [OUT_W-1:0] result
);
    localparam logic signed [ACC_W:0] MAX_OUT =
        {{(ACC_W+1-OUT_W){1'b0}}, 1'b0, {(OUT_W-1){1'b1}}};
    localparam logic signed [ACC_W:0] MIN_OUT =
        -({{(ACC_W+1-OUT_W){1'b0}}, 1'b1, {(OUT_W-1){1'b0}}});
    logic signed [ACC_W:0] wide_value, rounded_value;
    logic [ACC_W:0] magnitude, rounded_magnitude;

    assign wide_value = {value[ACC_W-1], value};
    assign magnitude = value[ACC_W-1] ? $unsigned(-wide_value) : $unsigned(wide_value);
    // 先按绝对值舍入再恢复符号，负半值也远离零。
    if (SHIFT > 0) begin : gen_shift
        localparam logic [ACC_W:0] HALF = {{ACC_W{1'b0}}, 1'b1} << (SHIFT-1);
        assign rounded_magnitude = (magnitude + HALF) >> SHIFT;
    end else begin : gen_no_shift
        assign rounded_magnitude = magnitude;
    end
    assign rounded_value = value[ACC_W-1] ? -$signed(rounded_magnitude) : $signed(rounded_magnitude);
    always_comb begin
        if (rounded_value > MAX_OUT) result = MAX_OUT[OUT_W-1:0];
        else if (rounded_value < MIN_OUT) result = MIN_OUT[OUT_W-1:0];
        else result = rounded_value[OUT_W-1:0];
    end
endmodule
`default_nettype wire
