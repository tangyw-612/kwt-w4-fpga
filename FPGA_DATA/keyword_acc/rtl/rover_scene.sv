`default_nettype none
module rover_scene #(
    parameter bit FULL_ENCODER = 0,
    parameter bit COLOR_BARS = 0
)(
    input wire clk, rst_n, frame_start,
    input wire [10:0] x,
    input wire [9:0] y,
    input wire [2:0] car_col, car_row,
    input wire [39:0] trail,
    input wire result_valid, running, check_pass,
    input wire [1:0] direction, match_count,
    input wire [31:0] value0, value1, cycles,
    input wire [3:0] layers_completed,
    output logic [23:0] pixel
);
    localparam logic [23:0] BG = 24'h0a161e, PANEL = 24'h11252f, GRID = 24'h244854;
    localparam logic [23:0] WHITE = 24'he8f5f1, MINT = 24'h75f0c9, MUTED = 24'h9eb6b9;
    logic [2:0] shown_col, shown_row;
    logic [39:0] shown_trail;
    logic shown_valid, shown_running, shown_pass;
    logic [1:0] shown_direction, shown_matches;
    logic [31:0] shown_value0, shown_value1, shown_cycles;
    logic [3:0] shown_layers;

    // 只在消隐区锁存显示状态，避免运动时一帧内出现两个车位。
    always_ff @(posedge clk) begin
        if (!rst_n || frame_start) begin
            shown_col <= !rst_n ? 3'd2 : car_col;
            shown_row <= !rst_n ? 3'd3 : car_row;
            shown_trail <= !rst_n ? 40'b1 << 26 : trail;
            shown_valid <= rst_n && result_valid;
            shown_running <= rst_n && running;
            shown_pass <= rst_n && check_pass;
            shown_direction <= direction;
            shown_matches <= match_count;
            shown_value0 <= value0;
            shown_value1 <= value1;
            shown_cycles <= cycles;
            shown_layers <= layers_completed;
        end
    end

    wire [8:0] map_x = x[8:0] - 9'd32;
    wire [8:0] map_y = y[8:0] - 9'd96;
    wire [2:0] col_id = map_x[8:6], row_id = map_y[8:6];
    wire [5:0] tile_x = map_x[5:0], tile_y = map_y[5:0];
    wire in_map = x >= 32 && x < 480 && y >= 96 && y < 416;
    wire car_tile = col_id == shown_col && row_id == shown_row;
    wire [9:0] progress_x = x[9:0] - 10'd16;
    wire [3:0] layer_units = shown_layers >= 10 ? shown_layers - 4'd10 : shown_layers;
    logic [23:0] base_color, ink_color;
    logic [127:0] line_text;
    logic [10:0] text_x;
    logic [9:0] text_y;
    logic large_text, text_area;

    function automatic [63:0] display_hex(input [31:0] value);
        logic [3:0] digit;
        for (int i = 0; i < 8; i++) begin
            digit = value[i*4 +: 4];
            display_hex[i*8 +: 8] = digit < 10 ? 8'h30 + {4'b0, digit} : 8'h37 + {4'b0, digit};
        end
    endfunction

    always_comb begin
        base_color = BG;
        if (in_map) begin
            base_color = PANEL;
            if (tile_x == 0 || tile_y == 0) base_color = GRID;
            if (shown_trail[{row_id, col_id}] && tile_x >= 24 && tile_x < 40 && tile_y >= 24 && tile_y < 40)
                base_color = 24'h2f8176;
            if (col_id == 6 && row_id == 0 && tile_x >= 22 && tile_x < 42 && tile_y >= 22 && tile_y < 42)
                base_color = 24'hffc776;
            if (car_tile && tile_x >= 12 && tile_x < 52 && tile_y >= 12 && tile_y < 52) begin
                base_color = MINT;
                if (tile_x >= 19 && tile_x < 45 && (tile_y < 20 || tile_y >= 44)) base_color = 24'h29555b;
                if (tile_x >= 24 && tile_x < 40 && tile_y >= 25 && tile_y < 39) base_color = 24'h173f40;
            end
        end else if (x >= 502 && x < 776 && y >= 82 && y < 415) base_color = PANEL;
        if (FULL_ENCODER && x >= 16 && x < 784 && y >= 432 && y < 455 && progress_x[5:0] < 58)
            base_color = progress_x[9:6] < shown_layers ? MINT : GRID;

        line_text = "                ";
        ink_color = WHITE;
        text_x = 0;
        text_y = 0;
        text_area = 1;
        large_text = 0;
        if (x >= 32 && x < 288 && y >= 20 && y < 34) begin
            text_x = x - 32; text_y = y - 20; line_text = "KWT-STAR        ";
        end else if (x >= 520 && y >= 20 && y < 34) begin
            text_x = x - 520; text_y = y - 20;
            line_text = FULL_ENCODER ? "W4 ENCODER      " : "W4 MAC DEMO     ";
            ink_color = MINT;
        end else if (x >= 32 && x < 288 && y >= 66 && y < 80) begin
            text_x = x - 32; text_y = y - 66; line_text = "ROVER MAP       "; ink_color = MUTED;
        end else if (x >= 520 && y >= 99 && y < 113) begin
            text_x = x - 520; text_y = y - 99; line_text = "COMMAND         "; ink_color = MUTED;
        end else if (x >= 520 && y >= 136 && y < 164) begin
            text_x = x - 520; text_y = y - 136; large_text = 1; ink_color = MINT;
            if (!shown_valid) line_text = "READY           ";
            else case (shown_direction)
                0: line_text = "RIGHT           ";
                1: line_text = "UP              ";
                2: line_text = "LEFT            ";
                default: line_text = "STOP            ";
            endcase
        end else if (x >= 520 && y >= 197 && y < 211) begin
            text_x = x - 520; text_y = y - 197;
            if (shown_running) line_text = "RUNNING         ";
            else if (!shown_valid) line_text = "WAIT FOR INPUT  ";
            else if (shown_pass) begin
                line_text = FULL_ENCODER ? "ENCODER PASS    " : "MAC PASS        "; ink_color = MINT;
            end else begin
                line_text = FULL_ENCODER ? "ENCODER FAIL    " : "MAC FAIL        "; ink_color = 24'hff7777;
            end
        end else if (x >= 520 && y >= 243 && y < 257) begin
            text_x = x - 520; text_y = y - 243;
            if (FULL_ENCODER) line_text = {"CYCLES ", display_hex(shown_cycles), " "};
            else line_text = {"DOT0 ", display_hex(shown_value0), "   "};
        end else if (x >= 520 && y >= 274 && y < 288) begin
            text_x = x - 520; text_y = y - 274;
            if (FULL_ENCODER) line_text = {"LAYERS ", (shown_layers >= 10 ? "1" : "0"),
                8'h30 + {4'b0, layer_units}, "/12    "};
            else line_text = {"DOT1 ", display_hex(shown_value1), "   "};
        end else if (x >= 520 && y >= 319 && y < 333) begin
            text_x = x - 520; text_y = y - 319; ink_color = MUTED;
            if (FULL_ENCODER) line_text = "UART HOST       ";
            else line_text = {"MATCH ", 8'h30 + {6'b0, shown_matches}, "/2       "};
        end else if (!FULL_ENCODER && x >= 32 && x < 288 && y >= 443 && y < 457) begin
            text_x = x - 32; text_y = y - 443; ink_color = MUTED;
            line_text = "PL KEY OR UART  ";
        end else text_area = 0;
    end

    wire [3:0] char_index = large_text ? text_x[8:5] : text_x[7:4];
    wire [7:0] character = line_text[(15 - char_index)*8 +: 8];
    wire [2:0] glyph_x = large_text ? text_x[4:2] : text_x[3:1];
    wire [2:0] glyph_y = large_text ? text_y[4:2] : text_y[3:1];
    wire glyph_ink;
    lcd_font u_font (.character(character), .col(glyph_x), .row(glyph_y), .ink(glyph_ink));

    always_comb begin
        pixel = text_area && glyph_ink && (large_text ? text_x < 512 : text_x < 256) ? ink_color : base_color;
        if (COLOR_BARS) begin
            if (x < 100) pixel = 24'hffffff;
            else if (x < 200) pixel = 24'hffff00;
            else if (x < 300) pixel = 24'h00ffff;
            else if (x < 400) pixel = 24'h00ff00;
            else if (x < 500) pixel = 24'hff00ff;
            else if (x < 600) pixel = 24'hff0000;
            else if (x < 700) pixel = 24'h0000ff;
            else pixel = 0;
        end
    end
endmodule
`default_nettype wire
