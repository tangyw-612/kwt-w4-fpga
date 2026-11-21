`default_nettype none

// 编码器将部分写拆成十六位切片掩码。浅存储放入分布式存储器。
module w4_fpga_sp16 #(
    parameter int ADDR_BITS = 10
) (
    input wire clk,
    input wire enable,
    input wire write_word,
    input wire [ADDR_BITS-1:0] address,
    input wire [15:0] data_in,
    input wire [15:0] write_mask_n,
    output logic [15:0] data_out
);
    wire slice_write = write_word && !(&write_mask_n);
    if (ADDR_BITS <= 7) begin : g_lutram
        (* ram_style = "distributed" *) logic [15:0] words [0:(1 << ADDR_BITS)-1];
        always_ff @(posedge clk)
            if (enable) begin
                if (slice_write) words[address] <= data_in;
                else if (!write_word) data_out <= words[address];
            end
    end else begin : g_bram
        (* ram_style = "block" *) logic [15:0] words [0:(1 << ADDR_BITS)-1];
        always_ff @(posedge clk)
            if (enable) begin
                if (slice_write) words[address] <= data_in;
                else if (!write_word) data_out <= words[address];
            end
    end
`ifndef SYNTHESIS
    // 掩码全开或全关，避免误用逐位写时覆盖其他位。
    always @(posedge clk) if (enable && write_word &&
        write_mask_n !== 16'h0000 && write_mask_n !== 16'hffff)
        $fatal(1, "存储切片只支持整片写入 mask=%h", write_mask_n);
`endif
endmodule

// 连接名保留芯片宏的命名，便于直接适配归档的编码器。
`define W4_SRAM_WRAPPER(MODULE_NAME, WIDTH_BITS) \
module MODULE_NAME ( \
    output wire [15:0] Q, \
    input wire CLK, CEN, GWEN, RET1N, \
    input wire [WIDTH_BITS-1:0] A, \
    input wire [15:0] WEN, D, \
    input wire [2:0] EMA, \
    input wire [1:0] EMAW \
); \
    w4_fpga_sp16 #(.ADDR_BITS(WIDTH_BITS)) u_ram( \
        .clk(CLK), .enable(!CEN && RET1N), .write_word(!GWEN), \
        .address(A), .data_in(D), .write_mask_n(WEN), .data_out(Q) \
    ); \
endmodule

`W4_SRAM_WRAPPER(RAMSP128X16, 7)
`W4_SRAM_WRAPPER(RAMSP1024X16, 10)
`W4_SRAM_WRAPPER(RAMSP4096X16, 12)
`undef W4_SRAM_WRAPPER
`default_nettype wire
