`default_nettype none
module ln_divider_fast (
    input logic clk, rst_n, start,
    input logic [56:0] numerator,
    input logic [31:0] denominator,
    output logic start_ready, done, error,
    output logic [56:0] quotient
);
    logic busy_q;
    logic [5:0] count_q;
    logic [56:0] number_q, quotient_q, next_quotient;
    logic [31:0] denominator_q, remainder_q;
    logic [32:0] shifted, reduced;
    logic unused_reduced_high;
    assign unused_reduced_high = reduced[32];
    assign start_ready = !busy_q;
    assign shifted = {remainder_q, number_q[56]};
    function automatic [39:0] sub40(input logic [39:0] a,b);
        logic [8:0] t; logic c; integer k; begin c=1;for(k=0;k<5;k=k+1)begin t={1'b0,a[k*8+:8]}+{1'b0,b[k*8+:8]};sub40[k*8+:8]=t[7:0]+c;c=t[8]|((&(a[k*8+:8]^b[k*8+:8]))&c);end end
    endfunction
    wire [39:0] diff=sub40({7'b0,shifted},{7'b0,~{1'b0,denominator_q}});
    wire ge=diff[33];
    assign reduced = ge ? diff[32:0] : shifted;
    assign next_quotient = (quotient_q << 1) | {56'b0, ge};
    // 无符号长除法。舍入与符号恢复由调用方独立处理。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_q <= 0; count_q <= 0; number_q <= 0; quotient_q <= 0;
            denominator_q <= 0; remainder_q <= 0; quotient <= 0; done <= 0; error <= 0;
        end else begin
            done <= 0;
            if (start && start_ready) begin
                error <= denominator == 0;
                if (denominator == 0) begin quotient <= 0; done <= 1; end
                else begin
                    busy_q <= 1; count_q <= 0; number_q <= numerator;
                    denominator_q <= denominator; remainder_q <= 0; quotient_q <= 0;
                end
            end else if (busy_q) begin
                number_q <= number_q << 1; quotient_q <= next_quotient;
                remainder_q <= reduced[31:0]; count_q <= count_q + 1'b1;
                if (count_q == 56) begin quotient <= next_quotient; done <= 1; busy_q <= 0; end
            end
        end
    end
endmodule

// 输入已确认是固定 57 位分子和至少 1048 的归一化分母。
module ln_recip_radix4 (
    input logic clk, rst_n, start,
    input logic [56:0] numerator,
    input logic [31:0] denominator,
    output logic start_ready, done, error,
    output logic [56:0] quotient
);
    logic busy;
    logic [4:0] digit;
    logic [47:0] remaining, q;
    logic [31:0] rem_q;
    logic [33:0] den1, den2, den3;
    wire [33:0] trial = {rem_q, remaining[47:46]};
    function automatic logic [34:0] subtract(input logic [33:0] a, b);
        logic carry;
        logic [7:0] block_sum;
        logic [34:0] a_ext, not_b;
        a_ext = {1'b0, a};
        not_b = {1'b1, ~b};
        carry = 1;
        for (int k = 0; k < 5; k++) begin
            block_sum = {1'b0, a_ext[7*k +: 7]} + {1'b0, not_b[7*k +: 7]} + 8'(carry);
            subtract[7*k +: 7] = block_sum[6:0];
            carry = block_sum[7] | ((&(a_ext[7*k +: 7] ^ not_b[7*k +: 7])) && carry);
        end
    endfunction
    wire [34:0] d1 = subtract(trial, den1);
    wire [34:0] d2 = subtract(trial, den2);
    wire [34:0] d3 = subtract(trial, den3);
    wire [1:0] bits = !d3[34] ? 2'd3 : !d2[34] ? 2'd2 : !d1[34] ? 2'd1 : 2'd0;
    wire [31:0] next_rem = !d3[34] ? d3[31:0] : !d2[34] ? d2[31:0] : !d1[34] ? d1[31:0] : trial[31:0];
    wire [47:0] next_q = {q[45:0], bits};
    assign start_ready = !busy;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin busy <= 0; done <= 0; error <= 0; quotient <= 0; end
        else begin
            done <= 0;
            if (start && start_ready) begin
                error <= denominator == 0;
                if (denominator == 0) begin done <= 1; quotient <= 0; end
                else begin
                    busy <= 1;
                    digit <= 0;
                    remaining <= numerator[47:0];
                    q <= 0;
                    rem_q <= 32'(numerator[56:48]);
                    den1 <= 34'(denominator);
                    den2 <= 34'(denominator) << 1;
                    den3 <= 34'(denominator) + (34'(denominator) << 1);
                end
            end else if (busy) begin
                rem_q <= next_rem;
                remaining <= {remaining[45:0], 2'b0};
                q <= next_q;
                digit <= digit + 1'b1;
                if (digit == 23) begin busy <= 0; done <= 1; quotient <= 57'(next_q); end
            end
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk) if (rst_n && start && start_ready && denominator != 0 &&
        32'(numerator[56:48]) >= denominator) $fatal(1, "radix-4 prefix does not fit");
`endif
endmodule
`default_nettype wire
