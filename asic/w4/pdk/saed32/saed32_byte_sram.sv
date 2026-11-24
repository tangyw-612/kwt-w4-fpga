`default_nettype none

// 每个物理宏管理一个字节；只有读请求才更新输出银行选择。
module saed32_byte_sram #(
    parameter int ADDR_BITS = 10
) (
    input wire clk, cen_n, write_n, retain_n,
    input wire [15:0] mask_n, data_in,
    input wire [ADDR_BITS-1:0] addr,
    output wire [15:0] data_out
);
    localparam int LOW_BITS = ADDR_BITS == 7 ? 7 : 10;
    localparam int BANKS = 1 << (ADDR_BITS - LOW_BITS);
    wire active = !cen_n && retain_n;
    wire read_en = active && write_n;
    wire [BANKS-1:0] bank_sel;
    wire [15:0] bank_data [BANKS];

    if (BANKS == 1) begin : g_single
        assign bank_sel = 1'b1;
        assign data_out = bank_data[0];
    end else begin : g_split
        logic [ADDR_BITS-LOW_BITS-1:0] read_bank;
        always_ff @(posedge clk)
            if (read_en) read_bank <= addr[ADDR_BITS-1:LOW_BITS];
        assign data_out = bank_data[read_bank];
        for (genvar b = 0; b < BANKS; b++) begin : g_decode
            assign bank_sel[b] = addr[ADDR_BITS-1:LOW_BITS] == b[ADDR_BITS-LOW_BITS-1:0];
        end
    end

    for (genvar b = 0; b < BANKS; b++) begin : g_bank
        for (genvar k = 0; k < 2; k++) begin : g_byte
            wire byte_write = !write_n && !mask_n[8*k];
            wire enable = active && bank_sel[b] && (write_n || byte_write);
            if (LOW_BITS == 7) begin : g_small
                SRAM1RW128x8 u_mem (.A(addr[6:0]), .CE(clk), .WEB(!byte_write),
                    .OEB(1'b0), .CSB(!enable), .I(data_in[8*k+:8]), .O(bank_data[b][8*k+:8]));
            end else begin : g_medium
                SRAM1RW1024x8 u_mem (.A(addr[9:0]), .CE(clk), .WEB(!byte_write),
                    .OEB(1'b0), .CSB(!enable), .I(data_in[8*k+:8]), .O(bank_data[b][8*k+:8]));
            end
        end
    end

`ifndef SYNTHESIS
    // W4 写掩码只按字节变化；遇到逐位掩码立即报告，避免静默写坏数据。
    always @(posedge clk) if (cen_n === 1'b0) begin
        if (retain_n !== 1'b1 || ((^{write_n, addr}) === 1'bx))
            $fatal(1, "SAED32_UNSUPPORTED_ACTIVE_CONTROL: %m");
        if (write_n === 1'b0 &&
            ((mask_n[7:0] !== 8'h00 && mask_n[7:0] !== 8'hff) ||
             (mask_n[15:8] !== 8'h00 && mask_n[15:8] !== 8'hff)))
            $fatal(1, "SAED32_NON_BYTE_MASK: %m mask=%h", mask_n);
    end
`endif
endmodule

`default_nettype wire
