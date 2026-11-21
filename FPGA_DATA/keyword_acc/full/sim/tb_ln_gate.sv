`timescale 1ns/1ps

module tb_ln_gate;
    bit clk = 0, rst_n = 0, start, parameter_set, load_valid, load_kind, in_valid;
    logic [6:0] load_addr;
    logic signed [31:0] load_data, in_a, in_b;
    wire rtl_start, rtl_error, rtl_ready, rtl_valid;
    wire gate_start, gate_error, gate_ready, gate_valid;
    wire signed [31:0] rtl_normalized, gate_normalized;
    wire [5:0] rtl_col, gate_col;
    int checked = 0;

    always #15 clk = !clk;
    ac_ln_stream #(.ROWS(100)) rtl (
        .clk, .rst_n, .start, .parameter_set, .load_valid, .load_kind, .load_addr, .load_data,
        .in_valid, .in_a, .in_b, .layer_index(4'd0), .position(1'b0), .out_ready(1'b1),
        .kwt_ln_storage(), .busy(), .done(), .load_ready(), .out_row(), .out_layer(), .out_position(),
        .start_ready(rtl_start), .load_error(rtl_error), .in_ready(rtl_ready), .out_valid(rtl_valid),
        .out_col(rtl_col), .out_residual(), .out_normalized(rtl_normalized)
    );
    ac_ln_stream_gate gate (
        .clk, .rst_n, .start, .parameter_set, .load_valid, .load_kind, .load_addr, .load_data,
        .in_valid, .in_a, .in_b, .layer_index(4'd0), .position(1'b0), .out_ready(1'b1),
        .kwt_ln_storage(), .busy(), .done(), .load_ready(), .out_row(), .out_layer(), .out_position(),
        .start_ready(gate_start), .load_error(gate_error), .in_ready(gate_ready), .out_valid(gate_valid),
        .out_col(gate_col), .out_residual(), .out_normalized(gate_normalized)
    );

    function automatic logic [31:0] little_endian(input logic [31:0] word);
        return {word[7:0], word[15:8], word[23:16], word[31:24]};
    endfunction

    always @(posedge clk) begin
        #1;
        if (rst_n) begin
            if (rtl_start !== gate_start || rtl_ready !== gate_ready || rtl_valid !== gate_valid)
                $fatal(1, "归一化控制门级差异 checked=%0d", checked);
            if (rtl_valid) begin
                // 编码器只连接归一化结果和列标记，残差观察端已在全核综合中剪除。
                if ({rtl_col, rtl_normalized} !== {gate_col, gate_normalized})
                    $fatal(1, "归一化门级差异 idx=%0d RTL=%h 网表=%h", checked, rtl_normalized, gate_normalized);
                checked++;
            end
        end
    end

    initial begin
        string vectors;
        logic [31:0] parameters [0:255];
        logic [31:0] inputs [0:255];
        int file_id, position_result;
        if (!$value$plusargs("vectors=%s", vectors)) $fatal(1, "缺少向量路径");
        file_id = $fopen($sformatf("%s/loader/parameters/layer_00.bin", vectors), "rb");
        if (file_id == 0) $fatal(1, "无法打开归一化参数");
        position_result = $fseek(file_id, 4*6880, 0);
        if (position_result != 0 || $fread(parameters, file_id) != 4*256)
            $fatal(1, "归一化参数长度错误");
        $fclose(file_id);
        file_id = $fopen($sformatf("%s/loader/sample_250/input.bin", vectors), "rb");
        if (file_id == 0 || $fread(inputs, file_id) != 4*256) $fatal(1, "激活向量长度错误");
        $fclose(file_id);

        repeat (12) @(posedge clk);
        #2;
        rst_n = 1;
        // 按控制器顺序装载两套伽马和贝塔，覆盖每个分片的写入掩码。
        for (int index = 0; index < 256; index++) begin
            load_valid = 1;
            load_kind = index[6];
            load_addr = {index[7], index[5:0]};
            load_data = little_endian(parameters[{index[7], index[5:0], index[6]}]);
            @(posedge clk);
            if (rtl_error !== 0 || gate_error !== 0) $fatal(1, "归一化参数装载错误 idx=%0d", index);
            #2;
        end
        load_valid = 0;
        wait (rtl_start);
        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;
        for (int row = 0; row < 4; row++) begin
            wait (rtl_ready);
            @(posedge clk);
            #2;
            parameter_set = row[0];
            for (int col = 0; col < 64; col++) begin
                in_valid = 1;
                in_a = little_endian(inputs[64*row + col]);
                in_b = 32'sd6151 * (32'(col) - 32'sd33) * (32'(row) + 32'sd1);
                @(posedge clk);
                #2;
            end
            in_valid = 0;
            wait (checked == 64*(row + 1));
        end
        $display("W4_GATE_LN_PASS parameters=256 results=%0d", checked);
        $finish;
    end

    initial begin
        repeat (10000) @(posedge clk);
        $fatal(1, "归一化功能网表仿真超时 checked=%0d", checked);
    end
endmodule
