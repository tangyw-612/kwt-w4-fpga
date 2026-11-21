`default_nettype none
module an970_competition_text (
    input wire clk,
    input wire [127:0] line,
    input wire [8:0] dx,
    input wire [7:0] dy,
    input wire [1:0] scale,
    input wire enable,
    input wire [23:0] ink,
    output wire text_pixel,
    output logic [23:0] text_rgb
);
    (* rom_style = "block" *) logic [15:0] glyphs [0:2047];
    initial $readmemh("an970_competition_glyphs.mem", glyphs);

    logic [7:0] grid_x;
    logic [4:0] glyph_y;
    wire [9:0] scaled_x = {dx, 1'b0} / 10'd3;
    wire [8:0] scaled_y = {dy, 1'b0} / 9'd3;
    always_comb begin
        // 半尺寸英文用于状态栏，中文和长词使用原字模，大字放大两倍。
        case (scale)
            0: begin grid_x = {dx[6:0], 1'b0}; glyph_y = {dy[3:0], 1'b0}; end
            2: begin grid_x = dx[8:1]; glyph_y = dy[5:1]; end
            3: begin grid_x = scaled_x[7:0]; glyph_y = scaled_y[4:0]; end
            default: begin grid_x = dx[7:0]; glyph_y = dy[4:0]; end
        endcase
    end
    wire [3:0] col = grid_x[3:0];
    wire [3:0] letter = grid_x[7:4];
    wire [7:0] character = line[{~letter, 3'b000} +: 8];
    logic [5:0] symbol;
    always_comb begin
        case (character)
            "#": symbol = 37;
            ".": symbol = 38;
            "/": symbol = 39;
            "-": symbol = 40;
            "m": symbol = 41;
            "s": symbol = 42;
            default: begin
                if (character >= "0" && character <= "9") symbol = 6'(character - "0");
                else if (character >= "A" && character <= "Z") symbol = 6'(character - "A" + 8'd10);
                else symbol = 36;
            end
        endcase
    end
    wire [10:0] glyph_addr = character[7]
        ? 11'd1376 + {character[5:0], glyph_y[3:0]} : {symbol, glyph_y};
    logic [15:0] glyph_bits;
    logic [3:0] col_q;
    logic enable_q;
    always_ff @(posedge clk) begin
        glyph_bits <= glyphs[glyph_addr];
        col_q <= col;
        enable_q <= enable && (!character[7] || glyph_y < 16);
        text_rgb <= ink;
    end
    assign text_pixel = enable_q && glyph_bits[col_q];
endmodule
`default_nettype wire
