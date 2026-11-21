// 固定有符号数据宽度，防止综合器从上游复用寄存器时丢失符号位。
module w4_dsp_mul27x17 #(
    parameter int B_SIGN_BIT = 16,
    parameter bit SELECT_W4_SIGN = 0
) (
    input wire clk, enable,
    input wire projection,
    input wire signed [26:0] a,
    input wire signed [16:0] b,
    output wire signed [43:0] product
);
    wire signed [16:0] b_wide = {{(16-B_SIGN_BIT){b[B_SIGN_BIT]}}, b[B_SIGN_BIT:0]};
    // 直接使用已实测正确的四位码，在原语入口恢复投影权重的符号。
    wire signed [16:0] b_signed = SELECT_W4_SIGN && projection ? {{13{b[3]}}, b[3:0]} : b_wide;
`ifdef W4_NATIVE_DSP
    wire [47:0] full_product;
    assign product = full_product[43:0];
    DSP48E2 #(
        .AREG(0), .ACASCREG(0), .BREG(0), .BCASCREG(0), .MREG(1), .PREG(0),
        .ADREG(0), .DREG(0), .CREG(0), .INMODEREG(0), .OPMODEREG(0),
        .ALUMODEREG(0), .CARRYINREG(0), .CARRYINSELREG(0),
        .AMULTSEL("A"), .BMULTSEL("B"), .A_INPUT("DIRECT"), .B_INPUT("DIRECT"),
        .USE_MULT("MULTIPLY"), .USE_SIMD("ONE48")
    ) u_product (
        .CLK(clk), .A({{3{a[26]}}, a}), .B({b_signed[16], b_signed}), .P(full_product),
        .OPMODE(9'b000000101), .INMODE(5'b0), .ALUMODE(4'b0),
        .CEM(enable), .CEA1(1'b0), .CEA2(1'b0), .CEB1(1'b0), .CEB2(1'b0),
        .CEAD(1'b0), .CEALUMODE(1'b0), .CEC(1'b0), .CECARRYIN(1'b0),
        .CECTRL(1'b0), .CED(1'b0), .CEINMODE(1'b0), .CEP(1'b0),
        .ACIN(30'b0), .BCIN(18'b0), .C(48'b0), .D(27'b0), .PCIN(48'b0),
        .CARRYCASCIN(1'b0), .CARRYIN(1'b0), .CARRYINSEL(3'b0), .MULTSIGNIN(1'b0),
        .RSTA(1'b0), .RSTB(1'b0), .RSTC(1'b0), .RSTD(1'b0), .RSTM(1'b0), .RSTP(1'b0),
        .RSTCTRL(1'b0), .RSTALUMODE(1'b0), .RSTINMODE(1'b0), .RSTALLCARRYIN(1'b0)
    );
`else
    logic signed [43:0] product_q;
    always_ff @(posedge clk) if (enable) product_q <= a * b_signed;
    assign product = product_q;
`endif
endmodule
