`timescale 1ns/1ps

module tb_full_stream;
    localparam int OUTPUT_WORDS = 6336;
    logic clk = 0;
    logic rst_n = 0;
    logic start = 0;
    logic in_valid = 0;
    logic [31:0] in_data = 0;
    logic out_ready = 0;
    wire in_ready, out_valid, busy, done;
    wire [31:0] out_data, cycles, wait_cycles;
    wire [3:0] layers_completed;
    string vectors, sample_id, path;
    logic [31:0] file_words [0:7136];
    logic [31:0] expected [0:OUTPUT_WORDS-1];
    int file_id, loaded, checked = 0;
    int stream_words = 0;
    bit paced;
    logic [31:0] payload_crc = 32'hffffffff;

    always #15 clk = !clk;
    w4_full_stream dut (.*);

`ifdef W4_GATE_FIRST_LAYER
    logic [31:0] expected_input [0:OUTPUT_WORDS-1];
    logic [31:0] expected_layer [0:OUTPUT_WORDS-1];
    bit layer_seen [0:OUTPUT_WORDS-1];
    int input_written = 0, layer_written = 0;
    wire activation_write = dut.u_core.u_x.wr;
    wire activation_pair = dut.u_core.u_x.pair_wr;
    wire [12:0] activation_address = dut.u_core.u_x.addr;
    wire [31:0] activation_data = dut.u_core.u_x.wdata;
    wire [31:0] activation_data_other = dut.u_core.u_x.wdata_other;

    initial begin
        int vec;
        string dir, id;
        if (!$value$plusargs("vectors=%s", dir) || !$value$plusargs("sample=%s", id))
            $fatal(1, "缺少 vectors 或 sample 参数");
        vec = $fopen($sformatf("%s/loader/%s/input.bin", dir, id), "rb");
        if (vec == 0 || $fread(expected_input, vec) != 4*OUTPUT_WORDS)
            $fatal(1, "首层门级输入向量读取失败");
        $fclose(vec);
        vec = $fopen($sformatf("%s/golden/%s/layer_00.bin", dir, id), "rb");
        if (vec == 0 || $fread(expected_layer, vec) != 4*OUTPUT_WORDS)
            $fatal(1, "首层门级参考向量读取失败");
        $fclose(vec);
    end

    task automatic check_first_layer(input int index, input logic [31:0] data);
        if (index < 0 || index >= OUTPUT_WORDS || layer_seen[index] ||
            data !== swap_bytes(expected_layer[index]))
            $fatal(1, "门级首层写回差异 idx=%0d got=%h expected=%h",
                   index, data, swap_bytes(expected_layer[index]));
        layer_seen[index] = 1;
    endtask

    // 激活端口在下降沿取样。先对照初始输入，再逐字检查第一层写回。
    always @(negedge clk) if (rst_n && activation_write) begin
        if (input_written < OUTPUT_WORDS) begin
            if (int'(activation_address) !== input_written ||
                activation_data !== swap_bytes(expected_input[input_written]))
                $fatal(1, "门级激活输入差异 idx=%0d addr=%0d got=%h expected=%h",
                       input_written, activation_address, activation_data,
                       swap_bytes(expected_input[input_written]));
            input_written++;
            if (input_written == OUTPUT_WORDS)
                $display("W4_GATE_INPUT_PASS words=%0d", input_written);
        end else begin
            if ($isunknown({activation_address, activation_pair}))
                $fatal(1, "门级首层写回地址或成对标记不确定");
            check_first_layer(int'(activation_address), activation_data);
            if (activation_pair)
                check_first_layer(int'(activation_address) + 64, activation_data_other);
            if (layer_written == 0)
                $display("W4_GATE_LAYER_FIRST_WORD addr=%0d data=%08h", activation_address, activation_data);
            layer_written += activation_pair ? 2 : 1;
            if (layer_written == OUTPUT_WORDS) begin
                $display("W4_GATE_FIRST_LAYER_PASS input=%0d output=%0d", input_written, layer_written);
                $finish;
            end
        end
    end
`endif

    function automatic logic [31:0] swap_bytes(input logic [31:0] word);
        return {word[7:0], word[15:8], word[23:16], word[31:24]};
    endfunction

    function automatic logic [31:0] crc_feed(input logic [31:0] seed, word);
        logic [31:0] crc;
        crc = seed;
        for (int bit_index = 0; bit_index < 32; bit_index++)
            crc = (crc >> 1) ^ ((crc[0] ^ word[bit_index]) ? 32'hedb88320 : 32'd0);
        return crc;
    endfunction

    task automatic send_file(input string file_path, input int count);
        file_id = $fopen(file_path, "rb");
        if (!file_id) $fatal(1, "无法打开向量 %s", file_path);
        loaded = $fread(file_words, file_id, 0, count);
        $fclose(file_id);
        if (loaded != 4*count) $fatal(1, "向量长度错误 %s", file_path);
        for (int i = 0; i < count; i++) begin
            @(negedge clk);
            in_valid = 1;
            in_data = swap_bytes(file_words[i]);
            do @(posedge clk); while (!in_ready);
            payload_crc = crc_feed(payload_crc, in_data);
            stream_words++;
            if (paced && stream_words % 256 == 0) begin
                @(negedge clk);
                in_valid = 0;
                // 模拟全局串口块边界。空闲时间缩短到仍可暴露等参状态。
                repeat (3072) @(negedge clk);
            end
        end
        @(negedge clk);
        in_valid = 0;
    endtask

    // 回压时保留同一字，并与最终回读向量逐字对照。
    logic [2:0] out_cycle = 0;
    always @(negedge clk) if (rst_n) begin
        out_cycle <= out_cycle + 1'b1;
        out_ready <= out_cycle != 3'd0 && out_cycle != 3'd1;
    end
    always @(posedge clk) if (rst_n && out_valid && out_ready) begin
        if (checked >= OUTPUT_WORDS || out_data !== swap_bytes(expected[checked]))
            $fatal(1, "最终回读差异 index=%0d got=%h expected=%h",
                   checked, out_data, swap_bytes(expected[checked]));
        checked <= checked + 1;
    end

    initial begin
        paced = $test$plusargs("paced");
        if (!$value$plusargs("vectors=%s", vectors) || !$value$plusargs("sample=%s", sample_id))
            $fatal(1, "缺少 vectors 或 sample 参数");
        path = $sformatf("%s/golden/%s/layer_11.bin", vectors, sample_id);
        file_id = $fopen(path, "rb");
        if (!file_id) $fatal(1, "无法打开最终参考 %s", path);
        loaded = $fread(expected, file_id);
        $fclose(file_id);
        if (loaded != 4*OUTPUT_WORDS) $fatal(1, "最终参考长度错误");

        repeat (5) @(negedge clk);
        rst_n = 1;
        start = 1;
        @(negedge clk);
        start = 0;
        send_file($sformatf("%s/loader/%s/input.bin", vectors, sample_id), OUTPUT_WORDS);
        send_file($sformatf("%s/loader/gelu.bin", vectors), 4097);
        send_file($sformatf("%s/loader/exp.bin", vectors), 4097);
        for (int layer = 0; layer < 12; layer++) begin
            if (paced && layer != 0) begin
                wait (layers_completed == 4'(layer));
                // 上一层算完以后仍空闲，再供下一层，覆盖参数比计算慢的情形。
                repeat (32768) @(negedge clk);
            end
            send_file($sformatf("%s/loader/parameters/layer_%02d.bin", vectors, layer), 7137);
        end
        if (stream_words != 100174) $fatal(1, "装载总字数错误");
        $display("W4_STREAM_PAYLOAD words=%0d crc32=%08h paced=%0d",
                 stream_words, ~payload_crc, paced);
        wait (done);
        @(negedge clk);
        if (busy || checked != OUTPUT_WORDS || layers_completed != 12)
            $fatal(1, "完整推理回读不完整");
        $display("W4_FULL_STREAM_PASS sample=%s layers=%0d words=%0d cycles=%0d wait_cycles=%0d",
                 sample_id, layers_completed, checked, cycles, wait_cycles);
        $finish;
    end

    initial begin
        repeat (5_000_000) @(posedge clk);
        $fatal(1, "完整推理仿真超时");
    end
endmodule
