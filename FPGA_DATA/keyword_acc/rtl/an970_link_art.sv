`default_nettype none
module an970_link_art (
    input wire clk,
    input wire [10:0] x,
    input wire [9:0] y,
    input wire [9:0] sample_id,
    input wire sample_valid,
    output logic logo_on, inverse_label,
    output wire label_on, wave_on,
    output wire [23:0] logo_rgb
);
    (* rom_style = "block" *) logic [3:0] logo [0:12287];
    (* rom_style = "block" *) logic [7:0] label_bitmap [0:4863];
    (* rom_style = "block" *) logic [4:0] waves [0:19199];
    logic [23:0] palette [0:15];
    logic [13:0] logo_addr;
    logic [15:0] label_addr, wave_addr;
    logic logo_region, label_region, label_inverse, text_region_q;
    logic [7:0] label_byte;
    logic [2:0] label_bit;
    logic [3:0] index;
    logic [7:0] local_x, local_y;
    logic [4:0] wave_height;
    logic [5:0] wave_offset_y;
    logic wave_region_q;
    wire [8:0] wave_x = 9'(x - 48);
    wire [5:0] distance_y = y >= 267 ? 6'(y - 267) : 6'(267 - y);
    wire plot_region = sample_valid && x >= 48 && x < 400 && y >= 205 && y < 330;

    initial begin
        $readmemh("an970_logo.mem", logo);
        $readmemh("an970_palette.mem", palette);
        $readmemh("an970_labels.mem", label_bitmap);
        $readmemh("an970_waves.mem", waves);
    end

    always_comb begin
        logo_region = 0;
        label_region = 1;
        label_inverse = 0;
        logo_addr = 0;
        local_x = 0;
        local_y = 0;
        if (x >= 32 && x < 160 && y >= 10 && y < 58) begin
            logo_region = 1;
            local_x = 8'(x - 32);
            local_y = 8'(y - 10);
            logo_addr = {1'b0, local_y[5:0], local_x[6:0]};
        end else if (x >= 538 && x < 762 && y >= 22 && y < 46) begin
            logo_region = 1;
            local_x = 8'(x - 538);
            local_y = 8'(y - 22);
            logo_addr = 14'd6144 + {1'b0, local_y[4:0], local_x};
        end

        // 位图按 256 像素行宽打包，坐标定点排布，字体不用整屏缓存。
        if (x >= 32 && x < 288 && y >= 76 && y < 110) begin
            local_x = 8'(x - 32); local_y = 8'(y - 76);
            if (local_y >= 32) label_region = 0;
        end else if (x >= 46 && x < 130 && y >= 130 && y < 151) begin
            local_x = 8'(x - 46); local_y = 8'(y - 130 + 32);
        end else if (x >= 452 && x < 536 && y >= 130 && y < 151) begin
            local_x = 8'(x - 452); local_y = 8'(y - 130 + 56);
            label_inverse = 1;
        end else if (x >= 46 && x < 123 && y >= 407 && y < 428) begin
            local_x = 8'(x - 46); local_y = 8'(y - 407 + 80);
        end else if (x >= 432 && x < 509 && y >= 407 && y < 428) begin
            local_x = 8'(x - 432); local_y = 8'(y - 407 + 104);
        end else if (x >= 46 && x < 123 && y >= 177 && y < 198) begin
            local_x = 8'(x - 46); local_y = 8'(y - 177 + 128);
        end else label_region = 0;
        label_addr = {local_y, local_x};
        wave_addr = plot_region ? {1'b0, sample_id, 5'(wave_x / 11)} : 16'd0;
    end

    always_ff @(posedge clk) begin
        index <= logo[logo_addr];
        label_byte <= label_bitmap[label_addr[15:3]];
        label_bit <= label_addr[2:0];
        logo_on <= logo_region;
        text_region_q <= label_region;
        inverse_label <= label_inverse;
        wave_height <= waves[wave_addr];
        wave_offset_y <= distance_y;
        wave_region_q <= plot_region && (wave_x % 11 >= 2) && (wave_x % 11 < 8);
    end

    assign logo_rgb = palette[index];
    assign label_on = text_region_q && label_byte[7 - label_bit];
    assign wave_on = wave_region_q && wave_height != 0 && wave_offset_y < {wave_height, 1'b0};
endmodule
`default_nettype wire
