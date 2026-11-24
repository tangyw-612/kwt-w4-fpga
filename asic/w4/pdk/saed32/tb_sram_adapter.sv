`timescale 1ns/1ps
`default_nettype none

module test_sram_depth #(parameter int AB = 10)(input wire clk, output bit done);
    localparam int WORDS = 1 << AB;
    bit cen_n = 1, write_n = 1, retain_n = 1;
    bit [AB-1:0] addr;
    bit [15:0] mask_n, data_in;
    wire [15:0] data_out;
    bit [15:0] expected [WORDS];
    logic [15:0] last_read = 'x;

    saed32_byte_sram #(.ADDR_BITS(AB)) dut (.*);

    task automatic cycle(input bit disable_mem, wr_n, keep_n,
        input int a, input bit [15:0] mask, data);
        @(negedge clk);
        cen_n = disable_mem; write_n = wr_n; retain_n = keep_n;
        addr = AB'(a); mask_n = mask; data_in = data;
        @(posedge clk);
        #1;
        if (!disable_mem && keep_n) begin
            if (wr_n) last_read = expected[a];
            else expected[a] = (expected[a] & mask) | (data & ~mask);
        end
        if (data_out !== last_read)
            $fatal(1, "AB=%0d addr=%0d read=%b cs=%b mask=%h exp=%h got=%h",
                AB, a, wr_n, disable_mem, mask, last_read, data_out);
    endtask

    initial begin
        for (int i = 0; i < WORDS; i++)
            cycle(0, 0, 1, i, '0, 16'((i * 71) ^ (i >> 5) ^ 'h56fa));
        for (int i = WORDS - 1; i >= 0; i--)
            cycle(0, 1, 1, i, '0, '0);
        // 相邻银行交错访问，覆盖写入时输出保持和跨银行选通。
        for (int i = 0; i < WORDS; i++) begin
            cycle(0, 0, 1, i, 16'hff00, 16'(~i));
            cycle(0, 1, 1, WORDS-1-i, '0, '0);
            cycle(0, 0, 1, i, 16'h00ff, 16'(i * 19));
            cycle(0, 0, 1, i, 16'hffff, '0);
            cycle(1, 0, 0, WORDS-1-i, '0, '0);
            cycle(1, 1, 1, WORDS-1-i, '0, '0);
        end
        for (int i = 0; i < WORDS; i++)
            cycle(0, 1, 1, i, '0, '0);
        $display("SAED32_SRAM_PASS depth=%0d cycles=%0d", WORDS, WORDS*9);
        done = 1'b1;
    end
endmodule

module tb_sram_adapter;
    bit clk = 0;
    wire [2:0] done;
    always #3.333 clk = !clk;
    test_sram_depth #(.AB(7)) small_cache (clk, done[0]);
    test_sram_depth #(.AB(10)) medium_cache (clk, done[1]);
    test_sram_depth #(.AB(12)) shared_bank (clk, done[2]);
    initial begin
        wait (&done);
        $finish;
    end
    initial #300000 $fatal(1, "SRAM adapter test timeout");
endmodule

`default_nettype wire
