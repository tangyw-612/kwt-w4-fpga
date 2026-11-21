`default_nettype none
module an970_competition_detail (
    input wire clk,
    input wire [10:0] x,
    input wire [9:0] y,
    output logic visible,
    output logic [23:0] rgb
);
    logic [52:0] logo_regions [0:1];
    logic [54:0] text_regions [0:9];
    logic [23:0] logo_palette [0:7];
    (* rom_style = "distributed" *) logic [9:0] tile_map [0:3583];
    (* rom_style = "block" *) logic [15:0] tiles [0:1023];
    initial begin
        $readmemh("an970_detail_logo_regions.mem", logo_regions);
        $readmemh("an970_detail_logo_palette.mem", logo_palette);
        $readmemh("an970_detail_map.mem", tile_map);
        $readmemh("an970_detail_tiles.mem", tiles);
        $readmemh("an970_detail_text_regions.mem", text_regions);
    end

    logic hit, is_logo, logo_select;
    logic [11:0] map_addr;
    logic [3:0] pixel_bit;
    logic [1:0] text_color;
    always_comb begin
        hit = 0;
        is_logo = 0;
        logo_select = 0;
        map_addr = 0;
        pixel_bit = 0;
        text_color = 0;
        for (int i = 0; i < 2; i++) begin
            logic [10:0] left, dx;
            logic [9:0] top, dy;
            logic [7:0] width_px;
            logic [5:0] height_px, pitch;
            logic [11:0] base;
            {left, top, width_px, height_px, base, pitch} = logo_regions[i];
            dx = x - left;
            dy = y - top;
            if (x >= left && y >= top && dx < {3'b0, width_px} && dy < {4'b0, height_px}) begin
                // 标志每个图块存四列两行，图块内各像素独立取色。
                hit = 1;
                is_logo = 1;
                logo_select = i[0];
                map_addr = base + 12'(dy[5:1]) * 12'(pitch) + 12'(dx[7:2]);
                pixel_bit = {dy[0], dx[1:0], 1'b0};
            end
        end

        for (int i = 0; i < 10; i++) begin
            logic [10:0] left, dx;
            logic [9:0] top, dy;
            logic [7:0] width_px;
            logic [5:0] height_px, pitch;
            logic [11:0] base;
            logic [1:0] color;
            {left, top, width_px, height_px, base, pitch, color} = text_regions[i];
            dx = x - left;
            dy = y - top;
            if (x >= left && y >= top && dx < {3'b0, width_px} && dy < {4'b0, height_px}) begin
                hit = 1;
                is_logo = 0;
                // 文字每个图块存四列四行，与标志共用一份 16 位 ROM。
                map_addr = base + 12'(dy[5:2]) * 12'(pitch) + 12'(dx[7:2]);
                pixel_bit = {dy[1:0], dx[1:0]};
                text_color = color;
            end
        end
    end

    logic [15:0] tile_q;
    logic hit_q, is_logo_q, logo_select_q;
    logic [3:0] pixel_bit_q;
    logic [1:0] text_color_q;
    always_ff @(posedge clk) begin
        tile_q <= tiles[tile_map[map_addr]];
        {hit_q, is_logo_q, logo_select_q} <= {hit, is_logo, logo_select};
        {pixel_bit_q, text_color_q} <= {pixel_bit, text_color};
    end

    wire [1:0] logo_index = tile_q[pixel_bit_q +: 2];
    always_comb begin
        if (is_logo_q) begin
            visible = hit_q && logo_index != 0;
            rgb = logo_palette[{logo_select_q, logo_index}];
        end else begin
            visible = hit_q && tile_q[pixel_bit_q];
            case (text_color_q)
                0: rgb = 24'h163857;
                1: rgb = 24'h486580;
                2: rgb = 24'hd8e8f8;
                default: rgb = 24'h087e91;
            endcase
        end
    end
endmodule
`default_nettype wire
