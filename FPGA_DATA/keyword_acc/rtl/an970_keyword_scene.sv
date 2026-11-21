`default_nettype none
module an970_keyword_scene (
    input wire clk, rst_n, frame_start,
    input wire [10:0] x,
    input wire [9:0] y,
    input wire [9:0] sample_id,
    input wire [127:0] wave,
    input wire [1:0] status,
    input wire [3:0] class_id, layers,
    input wire [31:0] cycles,
    output wire [23:0] pixel
);
    localparam [23:0] INK = 24'h164f7a, MUTED = 24'h486580, ICE = 24'hd8e8f8;
    localparam [23:0] MINT = 24'h8fe9d3, AMBER = 24'hffd387;

    logic [3:0] truth_table [0:11];
    logic [63:0] phrases [0:17];
    initial begin
        $readmemh("an970_competition_truth.mem", truth_table);
        $readmemh("an970_competition_phrases.mem", phrases);
    end
    wire [9:0] group = sample_id / 10'd50;
    wire [32:0] elapsed_ms = ({1'b0, cycles} + 33'd16666) / 33'd33333;
    logic [9:0] shown_id, shown_ms;
    logic [127:0] shown_wave;
    logic [1:0] shown_status;
    logic [3:0] shown_class, shown_truth, shown_layers;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            shown_id <= 0;
            shown_wave <= 0;
            shown_status <= 0;
            shown_class <= 0;
            shown_truth <= 0;
            shown_layers <= 0;
            shown_ms <= 0;
        end else if (frame_start) begin
            // 同帧锁存真实标签与推理回执，避免跨样本比较。
            shown_id <= sample_id;
            shown_wave <= wave;
            shown_status <= status;
            shown_class <= class_id;
            shown_truth <= truth_table[group[3:0]];
            shown_layers <= layers;
            shown_ms <= elapsed_ms > 999 ? 10'd999 : elapsed_ms[9:0];
        end
    end
    wire finished = shown_status == 2;
    wire same_label = shown_class == shown_truth;
    wire [23:0] accent = same_label ? MINT : AMBER;

    function automatic [23:0] decimal3(input [9:0] value);
        logic [9:0] hundreds, tens, units;
        begin
            hundreds = value / 10'd100;
            tens = (value / 10'd10) % 10'd10;
            units = value % 10'd10;
            return {8'h30 + {4'b0, hundreds[3:0]}, 8'h30 + {4'b0, tens[3:0]}, 8'h30 + {4'b0, units[3:0]}};
        end
    endfunction

    function automatic [63:0] keyword_text(input [3:0] category);
        case (category)
            0: return "SILENCE "; 1: return "UNKNOWN "; 2: return "YES     "; 3: return "NO      ";
            4: return "UP      "; 5: return "DOWN    "; 6: return "LEFT    "; 7: return "RIGHT   ";
            8: return "ON      "; 9: return "OFF     "; 10: return "STOP    "; 11: return "GO      ";
            default: return "ERROR   ";
        endcase
    endfunction

    wire [23:0] backdrop;
    an970_competition_backdrop u_backdrop (.clk, .rst_n, .x, .y, .rgb(backdrop));
    wire [8:0] plot_x = 9'(x - 56);
    wire [8:0] bar_column = plot_x / 9'd11;
    wire [8:0] bar_offset = plot_x % 9'd11;
    wire [3:0] amplitude = shown_wave[{bar_column[4:0], 2'b00} +: 4];
    wire [5:0] bar_height = {2'b0, amplitude} + {1'b0, amplitude, 1'b0};
    wire [9:0] wave_y = y >= 300 ? y - 10'd300 : 10'd300 - y;
    wire in_wave = x >= 56 && x < 408 && y >= 248 && y < 352;
    wire wave_ink = in_wave && (y == 300 ||
        (shown_status != 0 && bar_offset >= 2 && bar_offset < 8 && wave_y < {4'b0, bar_height}));

    // 表情与关键词共用同一帧的分类结果。
    wire [10:0] face_x = x >= 723 ? x - 11'd723 : 11'd723 - x;
    wire [9:0] face_y = y >= 223 ? y - 10'd223 : 10'd223 - y;
    wire [5:0] fx = face_x[5:0], fy = face_y[5:0];
    wire [12:0] face_radius = fx * fx + fy * fy;
    wire [11:0] mouth_square = fx * fx;
    wire [9:0] mouth_y = same_label ? 10'd234 - {6'b0, mouth_square[7:4]} :
                                       10'd226 + {6'b0, mouth_square[7:4]};
    wire in_face = finished && face_x < 28 && face_y < 28 && face_radius <= 13'd676;
    wire face_ink = face_radius >= 13'd576 || (fx >= 7 && fx <= 10 && y >= 214 && y < 220) ||
        (fx <= 11 && y >= mouth_y && y <= mouth_y + 10'd1);

    logic [23:0] bg_q;
    always_ff @(posedge clk)
        bg_q <= in_face ? (face_ink ? accent : same_label ? 24'h214b60 : 24'h4c4842)
                        : wave_ink ? 24'h008775 : backdrop;

    logic [127:0] line;
    logic [8:0] dx;
    logic [7:0] dy;
    logic [1:0] scale;
    logic [23:0] ink;
    logic enable;
    wire [23:0] id_text = decimal3(shown_id);
    wire [23:0] ms_text = decimal3(shown_ms);
    wire [7:0] layer_tens = shown_layers >= 10 ? "1" : " ";
    wire [7:0] layer_units = 8'h30 + {4'b0, (shown_layers >= 10 ? shown_layers - 4'd10 : shown_layers)};
    always_comb begin
        line = "                ";
        dx = 0;
        dy = 0;
        scale = 1;
        ink = INK;
        enable = 1;
        if (x >= 48 && x < 176 && y >= 151 && y < 215) begin
            dx = 9'(x - 48); dy = 8'(y - 151); scale = 2;
            line = shown_status != 0 ? {"#", id_text, "            "} : "#---            ";
        end else if (x >= 336 && x < 432 && y >= 128 && y < 144) begin
            dx = 9'(x - 336); dy = 8'(y - 128); ink = MUTED;
            line = {phrases[5'd12 + {3'b0, shown_status}], "        "};
        end else if (x >= 480 && x < 696 && y >= 186 && y < 250) begin
            dx = 9'(x - 480); dy = 8'(y - 186);
            ink = finished ? accent : ICE;
            scale = finished && shown_class < 2 ? 3 : 2;
            if (scale == 3 && dy >= 48) enable = 0;
            case (shown_status)
                1: begin line = "RUNNING         "; scale = 3; if (dy >= 48) enable = 0; end
                2: line = {keyword_text(shown_class), "        "};
                3: line = "ERROR           ";
                default: line = "READY           ";
            endcase
        end else if (finished && x >= 480 && x < 624 && y >= 274 && y < 290) begin
            dx = 9'(x - 480); dy = 8'(y - 274); ink = ICE;
            line = {phrases[{1'b0, shown_class}], "        "};
        end else if (finished && x >= 716 && x < 752 && y >= 310 && y < 326) begin
            dx = 9'(x - 716); dy = 8'(y - 310); scale = 0; ink = ICE;
            line = {"#", id_text, "            "};
        end else if (finished && x >= 549 && x < 617 && y >= 344 && y < 360) begin
            dx = 9'(x - 549); dy = 8'(y - 344); scale = 0; ink = ICE;
            line = {keyword_text(shown_truth), "        "};
        end else if (finished && x >= 668 && x < 753 && y >= 344 && y < 360) begin
            dx = 9'(x - 668); dy = 8'(y - 344); ink = accent;
            line = {phrases[same_label ? 5'd16 : 5'd17], "        "};
        end else if (x >= 183 && x < 270 && y >= 425 && y < 441) begin
            dx = 9'(x - 183); dy = 8'(y - 425); scale = 0;
            line = "FPGA LIVE       ";
        end else if (x >= 445 && x < 520 && y >= 425 && y < 441) begin
            dx = 9'(x - 445); dy = 8'(y - 425); scale = 0;
            line = finished ? {layer_tens, layer_units, " / 12         "} : "-- / 12         ";
        end else if (x >= 703 && x < 768 && y >= 425 && y < 441) begin
            dx = 9'(x - 703); dy = 8'(y - 425); scale = 0;
            line = finished ? {(ms_text[23:16] == "0" ? " " : ms_text[23:16]),
                               ms_text[15:0], " ms          "} : "-- ms           ";
        end else enable = 0;
    end
    wire text_pixel;
    wire [23:0] text_rgb;
    an970_competition_text u_text (.clk, .line, .dx, .dy, .scale, .enable, .ink, .text_pixel, .text_rgb);
    wire detail_visible;
    wire [23:0] detail_rgb;
    an970_competition_detail u_detail (.clk, .x, .y, .visible(detail_visible), .rgb(detail_rgb));
    assign pixel = text_pixel ? text_rgb : detail_visible ? detail_rgb : bg_q;
endmodule
`default_nettype wire
