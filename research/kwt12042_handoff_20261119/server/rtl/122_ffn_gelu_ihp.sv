`default_nettype none
module ffn_gelu_ihp #(
    parameter int TAG_W = 15
) (
    input logic clk, rst_n,
    input logic table_write,
    input logic [12:0] table_addr,
    input logic signed [31:0] table_data,
    input logic in_valid,
    output logic in_ready,
    input logic signed [15:0] in_data,
    input logic [TAG_W-1:0] in_tag,
    output logic out_valid,
    input logic out_ready,
    output logic signed [15:0] out_data,
    output logic [TAG_W-1:0] out_tag
);
    wire signed [31:0] even_macro_q,odd_q;logic signed [31:0] last_value,last_q;logic last_sel_q;
    wire signed [31:0] even_q=last_sel_q?last_q:even_macro_q;
    logic signed [31:0] a, b, interpolated;
    logic signed [16:0] offset;
    logic [14:0] position;
    logic [11:0] even_addr;
    logic odd_q_select, valid_q;
    logic output_valid_q;
    logic [TAG_W-1:0] tag_q;
    logic signed [15:0] input_out_q;
    logic signed [39:0] interpolation_q;
    wire advance_out=rst_n&&(!output_valid_q||out_ready);
    logic [2:0] remainder_q;
    logic signed [15:0] input_q, rounded;
    logic signed [39:0] interpolation;
    assign offset = {in_data[15], in_data} + 17'sd16384;
    assign position = (offset < 0) ? 15'd0 : (offset > 32767) ? 15'd32767 : offset[14:0];
    assign even_addr = {1'b0, position[14:4]} + 12'(position[3]);
    assign in_ready = rst_n && (!valid_q || advance_out);
    assign out_valid = output_valid_q;
    assign a = odd_q_select ? odd_q : even_q;
    assign b = odd_q_select ? even_q : odd_q;
    assign interpolation = 40'(a) * (40'sd8 - 40'({1'b0, remainder_q})) +
                           40'(b) * 40'({1'b0, remainder_q});
    linear_requantize #(.ACC_W(40), .OUT_W(32), .SHIFT(3)) u_interpolate (
         .value(interpolation_q), .result(interpolated));
    linear_requantize #(.ACC_W(32), .OUT_W(16), .SHIFT(13)) u_output (
        .value(interpolated), .result(rounded));
    assign out_data = (input_out_q >= 16384) ? input_out_q : (input_out_q <= -16384) ? 16'sd0 : rounded;
    wire accept=in_valid&&in_ready;
    wire ew=table_write&&!table_addr[0]&&!table_addr[12];wire ow=table_write&&table_addr[0];wire lw=table_write&&!table_addr[0]&&table_addr[12];
    wire er=accept&&!even_addr[11];wire lr=accept&&even_addr[11];
    always_ff @(posedge clk)begin if(lw)last_value<=table_data;if(lr)last_q<=last_value;if(accept)last_sel_q<=even_addr[11];end
    official_2048x32_1p even_mem(.clk(clk),.rst_n(rst_n),.wr(ew),.rd(er),.addr(ew?table_addr[11:1]:even_addr[10:0]),.data(table_data),.mask(32'hffffffff),.q(even_macro_q));
    official_2048x32_1p odd_mem(.clk(clk),.rst_n(rst_n),.wr(ow),.rd(accept),.addr(ow?table_addr[11:1]:position[14:4]),.data(table_data),.mask(32'hffffffff),.q(odd_q));
`ifndef SYNTHESIS
    always @(posedge clk)if((ew&&er)||(ow&&accept)||(lw&&lr))$fatal(1,"GELU table single-port conflict");
`endif
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_q <= 0; output_valid_q <= 0;
            input_q <= 0; input_out_q <= 0; remainder_q <= 0;
            odd_q_select <= 0; tag_q <= 0; out_tag <= 0; interpolation_q <= 0;
        end else begin
            if (advance_out) begin
                output_valid_q <= valid_q;
                if (valid_q) begin
                    interpolation_q <= interpolation;
                    input_out_q <= input_q;
                    out_tag <= tag_q;
                end
            end
            if (in_ready) begin
                valid_q <= in_valid;
                if (in_valid) begin
                    input_q <= in_data;
                    remainder_q <= position[2:0];
                    odd_q_select <= position[3];
                    tag_q <= in_tag;
                end
            end
        end
    end
endmodule
`default_nettype wire
