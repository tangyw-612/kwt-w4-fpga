`timescale 1ns/1ps

module tb_activation_address;
    bit clk = 0, rst_n = 0;
    bit wr = 0, rd = 0, pair_wr = 0, pair_rd = 0, col_pair_rd = 0;
    logic [12:0] addr = 0;
    logic [31:0] wdata = 0, wdata_other = 0;
    wire [31:0] q, q_other, q_odd, q_other_odd;
    always #15 clk = !clk;
    ac_pair_x dut (.*);

    function automatic logic [31:0] value_at(input int unsigned index);
        return 32'hb47ac000 ^ (32'h01e293d5 * index);
    endfunction

    task automatic verify_read(input int unsigned index, input bit paired);
        @(posedge clk);
        #1;
        wr = 0;
        pair_wr = 0;
        rd = 1;
        pair_rd = paired;
        col_pair_rd = paired;
        addr = 13'(index);
        @(posedge clk);
        #1;
        if (q !== value_at(index))
            $fatal(1, "读回地址错误 idx=%d out=%h expected=%h", index, q, value_at(index));
        if (paired && (q_other !== value_at(index + 64) ||
                       q_odd !== value_at(index + 1) ||
                       q_other_odd !== value_at(index + 65)))
            $fatal(1, "并行读回地址错误 idx=%d", index);
    endtask

    initial begin
        repeat (12) @(posedge clk);
        #1;
        rst_n = 1;
        // 使用编码最后一层的双行写回形态，保留最后一行单写。
        for (int row = 0; row < 99; row += 2) begin
            for (int col = 0; col < 64; col++) begin
                @(posedge clk);
                #1;
                wr = 1;
                pair_wr = row != 98;
                addr = 13'(64 * row + col);
                wdata = value_at(64 * row + col);
                wdata_other = value_at(64 * (row + 1) + col);
            end
        end
        // 普通回读逐行跨过所有地址高位，尤其是深度换银行边界。
        for (int index = 0; index < 6336; index++)
            verify_read(index, 0);
        verify_read(0, 1);
        verify_read(62, 1);
        verify_read(64 * 62, 1);
        verify_read(64 * 64, 1);
        verify_read(64 * 96 + 62, 1);
        $display("W4_ACTIVATION_ADDRESS_PASS words=6336 paired_checks=5");
        $finish;
    end
endmodule
