`timescale 1ns/1ps

module IBUFDS(input wire I, IB, output wire O);
    assign O = I;
endmodule

module BUFG(input wire I, output wire O);
    assign O = I;
endmodule

// 比赛位流使用 200 MHz 输入和 33.333 MHz 的 PL 时钟。
module MMCME4_BASE #(
    parameter real CLKIN1_PERIOD = 5.0, CLKFBOUT_MULT_F = 5.0, CLKOUT0_DIVIDE_F = 30.0,
    parameter int DIVCLK_DIVIDE = 1
) (
    input wire CLKIN1, CLKFBIN, RST, PWRDWN,
    output wire CLKFBOUT,
    output logic CLKOUT0 = 0, LOCKED = 0
);
    logic [1:0] divider = 0;
    assign CLKFBOUT = CLKIN1;
    initial begin
        if (CLKIN1_PERIOD != 5.0 || CLKFBOUT_MULT_F != 5.0 ||
            CLKOUT0_DIVIDE_F != 30.0 || DIVCLK_DIVIDE != 1)
            $fatal(1, "比赛版时钟配置不匹配");
    end
    always @(posedge CLKIN1) begin
        if (RST || PWRDWN) begin
            divider <= 0; CLKOUT0 <= 0; LOCKED <= 0;
        end else if (divider == 2) begin
            divider <= 0; CLKOUT0 <= ~CLKOUT0; LOCKED <= 1;
        end else divider <= divider + 1'b1;
    end
endmodule

module ODDRE1(input wire C, D1, D2, SR, output wire Q);
    assign Q = SR ? 1'b0 : (C ? D1 : D2);
endmodule
