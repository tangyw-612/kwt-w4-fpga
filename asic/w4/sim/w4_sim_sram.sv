`timescale 1ns/1ps
`default_nettype none

// 仅用于 RTL 仿真。这里描述同步读、低有效写掩码和禁用时保持读出。
module w4_sim_sram #(parameter integer ADDR_WIDTH = 7) (
    output reg [15:0] Q,
    input wire CLK, CEN, GWEN, RET1N,
    input wire [15:0] WEN, D,
    input wire [ADDR_WIDTH-1:0] A
);
    reg [15:0] words [0:(1 << ADDR_WIDTH)-1];
    integer bit_index;
    always @(posedge CLK) begin
        if (!CEN && RET1N) begin
            if (GWEN) begin
                Q <= words[A];
            end else begin
                for (bit_index = 0; bit_index < 16; bit_index = bit_index + 1) begin
                    if (!WEN[bit_index]) words[A][bit_index] <= D[bit_index];
                end
            end
        end
    end
endmodule

module RAMSP128X16 (
    output wire [15:0] Q,
    input wire CLK, CEN, GWEN, RET1N,
    input wire [15:0] WEN, D,
    input wire [6:0] A,
    input wire [2:0] EMA,
    input wire [1:0] EMAW
);
    w4_sim_sram #(.ADDR_WIDTH(7)) u_sim (
        .Q(Q), .CLK(CLK), .CEN(CEN), .GWEN(GWEN), .RET1N(RET1N), .WEN(WEN), .D(D), .A(A)
    );
endmodule

module RAMSP1024X16 (
    output wire [15:0] Q,
    input wire CLK, CEN, GWEN, RET1N,
    input wire [15:0] WEN, D,
    input wire [9:0] A,
    input wire [2:0] EMA,
    input wire [1:0] EMAW
);
    w4_sim_sram #(.ADDR_WIDTH(10)) u_sim (
        .Q(Q), .CLK(CLK), .CEN(CEN), .GWEN(GWEN), .RET1N(RET1N), .WEN(WEN), .D(D), .A(A)
    );
endmodule

module RAMSP4096X16 (
    output wire [15:0] Q,
    input wire CLK, CEN, GWEN, RET1N,
    input wire [15:0] WEN, D,
    input wire [11:0] A,
    input wire [2:0] EMA,
    input wire [1:0] EMAW
);
    w4_sim_sram #(.ADDR_WIDTH(12)) u_sim (
        .Q(Q), .CLK(CLK), .CEN(CEN), .GWEN(GWEN), .RET1N(RET1N), .WEN(WEN), .D(D), .A(A)
    );
endmodule

`default_nettype wire
