`default_nettype none

// 将归档参数字拆成编码器装入口接受的分区、地址与数据。
module w4_parameter_decode (
    input wire [12:0] index,
    input wire [31:0] data,
    input wire [2:0] beat,
    output logic [63:0] word,
    output logic last_beat
);
    logic [14:0] logical_index;
    logic [12:0] offset;
    logic [8:0] bias_index;
    logic [3:0] region;
    logic [27:0] address;
    logic [31:0] value;

    always_comb begin
        logical_index = (15'(index) - 15'd288) << 2;
        if (index >= 13'd6432)
            logical_index = 15'(index) - 15'd6432 + 15'd24576;

        offset = 0;
        bias_index = 0;
        region = 0;
        address = 0;
        value = data;
        last_beat = 1;

        if (index < 13'd288) begin
            region = 4'd11;
            address = 28'(index);
        end else if (logical_index < 15'd24576) begin
            // 总线字内的两个通道交错存放，每个通道四个四位权重。
            for (int k = 0; k < 4; k++) begin
                value[4*k +: 4] = data[8*k +: 4];
                value[16+4*k +: 4] = data[8*k+4 +: 4];
            end
            if (logical_index < 15'd8192) begin
                region = 4'd2;
                address = 28'({logical_index[9:6], 1'b0, logical_index[12:11],
                               logical_index[10], logical_index[5:0]});
            end else if (logical_index < 15'd16384) begin
                offset = 13'(logical_index - 15'd8192);
                region = 4'd3;
                address = 28'({offset[9:6], 1'b0, 1'b0, offset[12:10], offset[5:0]});
            end else begin
                offset = 13'(logical_index - 15'd16384);
                region = 4'd3;
                address = 28'({offset[11:8], 1'b0, 1'b1, offset[12], offset[7:0]});
            end
        end else if (logical_index < 15'd24704) begin
            region = 4'd4;
            address = 28'(logical_index - 15'd24576);
        end else if (logical_index < 15'd25024) begin
            bias_index = logical_index < 15'd24960
                ? 9'(9'd64 + (logical_index - 15'd24704))
                : 9'(9'd320 + (logical_index - 15'd24960));
            region = 4'd4;
            address = 28'({bias_index, beat[0]});
            value = beat[0] ? {32{data[31]}} : data;
            last_beat = beat[0];
        end else if (logical_index < 15'd25280) begin
            region = 4'd5;
            address = 28'(logical_index - 15'd25024);
        end else if (beat < 3'd5) begin
            region = 4'd9;
            address = 28'(beat);
            value = (data >> (6 * beat)) & 32'h3f;
            last_beat = 0;
        end else begin
            region = 4'd10;
            value = 0;
        end
        word = {region, address, value};
    end
endmodule

`default_nettype wire
