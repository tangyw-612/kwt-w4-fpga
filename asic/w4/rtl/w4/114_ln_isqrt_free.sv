`default_nettype none
module ln_isqrt_free (
    input logic clk, rst_n, start,
    input logic [63:0] radicand,
    output logic start_ready, done,
    output logic [31:0] result
);
    logic busy_q;
    logic [3:0] step_q;
    logic [63:0] rad_q;
    logic [35:0] rem_q;
    logic [31:0] root_q;
    wire [35:0] shifted = (rem_q << 4) | 36'(rad_q[63:60]);
    // 根的下一位为 d 时，试减量是 (4r+d)^2 - 16r^2 = 8rd + d^2。
    wire [35:0] delta1 = (36'(root_q) << 3) + 36'd1;
    wire [35:0] delta2 = (36'(root_q) << 4) + 36'd4;
    wire [35:0] delta3 = (36'(root_q) << 4) + (36'(root_q) << 3) + 36'd9;
    wire [36:0] d1 = {1'b0, shifted} - {1'b0, delta1};
    wire [36:0] d2 = {1'b0, shifted} - {1'b0, delta2};
    wire [36:0] d3 = {1'b0, shifted} - {1'b0, delta3};
    wire [1:0] digit = !d3[36] ? 2'd3 : !d2[36] ? 2'd2 : !d1[36] ? 2'd1 : 2'd0;
    wire [35:0] next_rem = !d3[36] ? d3[35:0] : !d2[36] ? d2[35:0] : !d1[36] ? d1[35:0] : shifted;
    wire [31:0] next_root = {root_q[29:0], digit};
    assign start_ready = !busy_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin busy_q <= 0; done <= 0; result <= 0; end
        else begin
            done <= 0;
            if (start && start_ready) begin
                busy_q <= 1; step_q <= 0; rad_q <= radicand; rem_q <= 0; root_q <= 0;
            end else if (busy_q) begin
                rad_q <= rad_q << 4;
                rem_q <= next_rem;
                root_q <= next_root;
                step_q <= step_q + 1'b1;
                if (step_q == 15) begin result <= next_root; done <= 1; busy_q <= 0; end
            end
        end
    end
endmodule
`default_nettype wire
