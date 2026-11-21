`default_nettype none
module an970_link_scene (
    input wire clk, rst_n, frame_start,
    input wire [10:0] x,
    input wire [9:0] y,
    input wire mac_done, mac_pass, unsupported,
    input wire [15:0] rejected_sample,
    input wire [1:0] direction, matched,
    input wire [31:0] value0, value1,
    input wire [7:0] cycles,
    output wire [23:0] pixel
);
    localparam [23:0] BG = 24'hecf4fa, HEADER = 24'hf8fcff, PANEL = 24'hfdfefe;
    localparam [23:0] NAVY = 24'h173857, INK = 24'h164f7a, MUTED = 24'h55718c;
    localparam [23:0] ICE = 24'hdcecf8, MINT = 24'h8fe9d3, AMBER = 24'hffd387;
    typedef enum logic [1:0] {WAITING, RESULT, NO_VECTOR} kind_t;
    typedef struct packed {
        kind_t kind;
        logic [15:0] sample;
        logic pass;
        logic [1:0] matched;
        logic [7:0] cycles;
        logic neg0, neg1;
        logic [39:0] bcd0, bcd1;
    } display_state_t;
    display_state_t pending, latest, shown;
    logic [71:0] working0, working1;
    logic [5:0] steps;
    logic [15:0] resolved_sample;

    always_comb begin
        case (direction)
            0: resolved_sample = 250;
            1: resolved_sample = 100;
            2: resolved_sample = 200;
            default: resolved_sample = 400;
        endcase
    end

    function automatic [71:0] bcd_step(input [71:0] current);
        reg [71:0] adjusted;
        adjusted = current;
        for (int digit = 0; digit < 10; digit++) begin
            if (adjusted[32 + digit*4 +: 4] >= 5)
                adjusted[32 + digit*4 +: 4] = adjusted[32 + digit*4 +: 4] + 4'd3;
        end
        return adjusted << 1;
    endfunction

    wire [71:0] next0 = bcd_step(working0);
    wire [71:0] next1 = bcd_step(working1);
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pending <= '0; latest <= '0; shown <= '0;
            working0 <= 0; working1 <= 0; steps <= 0;
        end else begin
            // 十进制转换只在结果事件后运行。所有字段在同一帧边界锁存。
            if (unsupported) begin
                latest <= '{kind: NO_VECTOR, sample: rejected_sample, default: '0};
                steps <= 0;
            end else if (mac_done) begin
                pending <= '{kind: RESULT, sample: resolved_sample, pass: mac_pass, matched: matched,
                             cycles: cycles, neg0: value0[31], neg1: value1[31], default: '0};
                working0 <= {40'd0, value0[31] ? (~value0 + 32'd1) : value0};
                working1 <= {40'd0, value1[31] ? (~value1 + 32'd1) : value1};
                steps <= 32;
            end else if (steps != 0) begin
                working0 <= next0;
                working1 <= next1;
                steps <= steps - 1'b1;
                if (steps == 1) begin
                    latest <= '{kind: pending.kind, sample: pending.sample, pass: pending.pass,
                                matched: pending.matched, cycles: pending.cycles, neg0: pending.neg0,
                                neg1: pending.neg1, bcd0: next0[71:32], bcd1: next1[71:32]};
                end
            end
            if (frame_start) shown <= latest;
        end
    end

    function automatic [87:0] signed_decimal(input [39:0] bcd, input negative);
        reg active;
        reg [3:0] digit;
        signed_decimal = "           ";
        active = 0;
        for (int pos = 9; pos >= 0; pos--) begin
            digit = bcd[pos*4 +: 4];
            if (active || digit != 0 || pos == 0) begin
                if (!active && negative) signed_decimal[(pos+1)*8 +: 8] = "-";
                signed_decimal[pos*8 +: 8] = 8'h30 + {4'd0, digit};
                active = 1;
            end
        end
    endfunction

    function automatic [23:0] decimal3(input [9:0] value, input pad_zero);
        reg [7:0] h, t, u;
        h = value < 100 && !pad_zero ? 8'h20 : 8'h30 + 8'(value / 100);
        t = value < 10 && !pad_zero ? 8'h20 : 8'h30 + 8'((value / 10) % 10);
        u = 8'h30 + 8'(value % 10);
        return {h, t, u};
    endfunction

    wire has_number = shown.kind != WAITING;
    wire has_result = shown.kind == RESULT;
    logic [23:0] base, ink, text_pixel_q;
    logic [127:0] line;
    logic [10:0] dx;
    logic [9:0] dy;
    logic text_on, large_text;
    wire [23:0] sample_digits = shown.sample < 1000 ? decimal3(shown.sample[9:0], 1) : "---";
    wire [8:0] plot_x = 9'(x - 48);

    always_comb begin
        base = BG;
        if (y < 64) base = HEADER;
        else if (y < 67) base = 24'h2b6698;
        else if (x >= 24 && x < 424 && y >= 116 && y < 382) base = PANEL;
        else if (x >= 436 && x < 776 && y >= 116 && y < 382) base = NAVY;
        else if (x >= 24 && x < 776 && y >= 396 && y < 456) base = PANEL;
        if (x >= 46 && x < 402 && y >= 201 && y < 333) begin
            base = 24'he8f3fa;
            if (y == 267 || (x >= 48 && x < 400 && plot_x % 9'd44 == 0)) base = 24'hc5ddec;
        end
        if (x >= 452 && x < 759 && (y == 235 || y == 292) ) base = 24'h52708d;
        if (x == 404 && y >= 404 && y < 447) base = 24'hc4d8e8;

        line = "                ";
        dx = 0;
        dy = 0;
        large_text = 0;
        text_on = 1;
        ink = INK;
        if (x >= 570 && y >= 85 && y < 99) begin
            dx = x - 570; dy = y - 85; line = "W4 MAC / J8     ";
        end else if (x >= 148 && x < 292 && y >= 125 && y < 153) begin
            dx = x - 148; dy = y - 125; large_text = 1;
            line = has_number ? {"#", sample_digits, "            "} : "#---            ";
        end else if (x >= 46 && x < 310 && y >= 352 && y < 366) begin
            dx = x - 46; dy = y - 352; line = "600 SAMPLES     "; ink = MUTED;
        end else if (x >= 452 && x < (has_result ? 561 : 760) && y >= 177 && y < 205) begin
            dx = x - 452; dy = y - 177; large_text = 1;
            ink = has_result && shown.pass ? MINT : (has_number ? AMBER : ICE);
            if (has_result) line = {8'h30 + {6'd0, shown.matched}, "/2             "};
            else line = has_number ? "NO VECTOR       " : "READY           ";
        end else if (x >= 609 && x < 760 && y >= 185 && y < 199 && has_result) begin
            dx = x - 609; dy = y - 185; line = shown.pass ? "PASS            " : "FAIL            ";
            ink = shown.pass ? MINT : AMBER;
        end else if (x >= 452 && x < 754 && y >= 257 && y < 271) begin
            dx = x - 452; dy = y - 257; ink = ICE;
            line = has_result ? {"DOT0 ", signed_decimal(shown.bcd0, shown.neg0)} : "DOT0 ---        ";
        end else if (x >= 452 && x < 754 && y >= 314 && y < 328) begin
            dx = x - 452; dy = y - 314; ink = ICE;
            line = has_result ? {"DOT1 ", signed_decimal(shown.bcd1, shown.neg1)} : "DOT1 ---        ";
        end else if (x >= 156 && x < 316 && y >= 411 && y < 425) begin
            dx = x - 156; dy = y - 411;
            line = has_result ? {decimal3({2'b0, shown.cycles}, 0), "             "} : "---             ";
        end else if (x >= 528 && x < 773 && y >= 411 && y < 425) begin
            dx = x - 528; dy = y - 411; line = "J8 / 921600     ";
        end else text_on = 0;
    end

    wire [3:0] char_index = large_text ? dx[8:5] : dx[7:4];
    wire [7:0] character = line[(15 - char_index)*8 +: 8];
    wire glyph;
    lcd_font u_font (.character(character), .col(large_text ? dx[4:2] : dx[3:1]),
                     .row(large_text ? dy[4:2] : dy[3:1]), .ink(glyph));
    always_ff @(posedge clk) text_pixel_q <= text_on && glyph && (large_text ? dx < 512 : dx < 256) ? ink : base;

    wire logo_on, label_on, inverse_label, wave_on;
    wire [23:0] logo_rgb;
    an970_link_art u_art (.clk(clk), .x(x), .y(y), .sample_id(shown.sample[9:0]),
                          .sample_valid(has_number && shown.sample < 600), .logo_on(logo_on),
                          .label_on(label_on), .inverse_label(inverse_label), .wave_on(wave_on), .logo_rgb(logo_rgb));
    assign pixel = logo_on ? logo_rgb : label_on ? (inverse_label ? ICE : INK)
                   : wave_on ? 24'h1885a7 : text_pixel_q;
endmodule
`default_nettype wire
