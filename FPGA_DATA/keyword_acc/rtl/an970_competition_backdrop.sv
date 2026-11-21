`default_nettype none
module an970_competition_backdrop (
    input wire clk, rst_n,
    input wire [10:0] x,
    input wire [9:0] y,
    output wire [23:0] rgb
);
    (* rom_style = "block" *) logic [8:0] runs [0:4095];
    (* rom_style = "distributed" *) logic [11:0] row_addr [0:239];
    logic [23:0] palette [0:15];
    initial begin
        $readmemh("an970_competition_pixels.mem", runs);
        $readmemh("an970_competition_rows.mem", row_addr);
        $readmemh("an970_competition_palette.mem", palette);
    end

    logic [11:0] cursor;
    logic [8:0] next_run;
    logic [6:0] remaining;
    logic [3:0] color;
    wire active = x < 800 && y < 480;
    wire [9:0] next_y = y == 504 ? 10'd0 : y + 10'd1;
    wire prepare_row = x == 1053 && (y < 479 || y == 504);
    wire take_run = rst_n && active && !x[0] && remaining == 0;
    wire [11:0] read_addr = cursor + 12'(take_run);

    function automatic [6:0] length_minus_one(input logic [4:0] symbol);
        case (symbol)
            28: return 7'd31;
            29: return 7'd47;
            30: return 7'd63;
            31: return 7'd127;
            default: return {2'b00, symbol};
        endcase
    endfunction

    always_ff @(posedge clk) begin
        next_run <= runs[read_addr];
        if (!rst_n) begin
            cursor <= 0;
            remaining <= 0;
            color <= 0;
        end else if (prepare_row) begin
            // 消隐期预取下一行。两个相邻像素共用一个颜色索引。
            cursor <= row_addr[next_y[8:1]];
            remaining <= 0;
        end else if (active && !x[0]) begin
            if (take_run) begin
                cursor <= read_addr;
                remaining <= length_minus_one(next_run[8:4]);
                color <= next_run[3:0];
            end else remaining <= remaining - 1'b1;
        end
    end
    assign rgb = palette[take_run ? next_run[3:0] : color];
endmodule
`default_nettype wire
