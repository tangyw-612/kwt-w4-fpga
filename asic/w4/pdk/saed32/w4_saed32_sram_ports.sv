`default_nettype none

// 保留 W4 实例接口。模拟调节引脚属于原工艺，SAED32 宏没有对应引脚。
module RAMSP128X16 (
    output wire [15:0] Q,
    input wire CLK, CEN,
    input wire [15:0] WEN,
    input wire [6:0] A,
    input wire [15:0] D,
    input wire [2:0] EMA,
    input wire [1:0] EMAW,
    input wire GWEN, RET1N
);
    saed32_byte_sram #(.ADDR_BITS(7)) u_adapter
        (.clk(CLK), .cen_n(CEN), .write_n(GWEN), .retain_n(RET1N),
         .mask_n(WEN), .data_in(D), .addr(A), .data_out(Q));
endmodule

module RAMSP1024X16 (
    output wire [15:0] Q,
    input wire CLK, CEN,
    input wire [15:0] WEN,
    input wire [9:0] A,
    input wire [15:0] D,
    input wire [2:0] EMA,
    input wire [1:0] EMAW,
    input wire GWEN, RET1N
);
    saed32_byte_sram #(.ADDR_BITS(10)) u_adapter
        (.clk(CLK), .cen_n(CEN), .write_n(GWEN), .retain_n(RET1N),
         .mask_n(WEN), .data_in(D), .addr(A), .data_out(Q));
endmodule

module RAMSP4096X16 (
    output wire [15:0] Q,
    input wire CLK, CEN,
    input wire [15:0] WEN,
    input wire [11:0] A,
    input wire [15:0] D,
    input wire [2:0] EMA,
    input wire [1:0] EMAW,
    input wire GWEN, RET1N
);
    saed32_byte_sram #(.ADDR_BITS(12)) u_adapter
        (.clk(CLK), .cen_n(CEN), .write_n(GWEN), .retain_n(RET1N),
         .mask_n(WEN), .data_in(D), .addr(A), .data_out(Q));
endmodule

`default_nettype wire
