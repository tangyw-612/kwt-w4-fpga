`default_nettype none

// 外部只缓存输入、查找表和模型。板端保留编码器内部存储。
module w4_full_stream (
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire in_valid,
    input wire [31:0] in_data,
    output wire in_ready,
    output wire out_valid,
    output wire [31:0] out_data,
    input wire out_ready,
    output wire busy,
    output logic done,
    output logic [3:0] layers_completed,
    output wire [31:0] cycles,
    output wire [31:0] wait_cycles
);
    localparam logic [12:0] LAST_INPUT = 13'd6335;
    localparam logic [12:0] LAST_TABLE = 13'd4096;
    localparam logic [12:0] LAST_PARAM = 13'd7136;

    typedef enum logic [2:0] {
        IDLE, INPUT_WORDS, GELU_WORDS, EXP_WORDS, PARAM_WORDS, WAIT_CORE,
        OUTPUT_READ, OUTPUT_WORD
    } state_t;
    state_t state;
    logic [12:0] index;
    logic [3:0] parameter_layer;
    logic [2:0] beat;
    logic [31:0] pending_data;
    logic pending;
    logic core_start, core_done_seen;
    wire core_done, layer_done, ld_ready;
    logic [63:0] load_word;
    wire [63:0] parameter_word;
    wire last_parameter_beat;
    wire load_last = state != PARAM_WORDS || last_parameter_beat;
    wire loading = state == INPUT_WORDS || state == GELU_WORDS ||
                   state == EXP_WORDS || state == PARAM_WORDS;
    wire ld_valid = loading && pending;

    assign in_ready = loading && !pending;
    assign out_valid = state == OUTPUT_WORD;
    assign busy = state != IDLE;

    w4_parameter_decode u_decoder (
        .index(index), .data(pending_data), .beat(beat),
        .word(parameter_word), .last_beat(last_parameter_beat)
    );

    always_comb begin
        case (state)
            INPUT_WORDS: load_word = {4'd1, 28'(index), pending_data};
            GELU_WORDS:  load_word = {4'd8, 28'(index), pending_data};
            EXP_WORDS:   load_word = {4'd7, 28'(index), pending_data};
            default:     load_word = parameter_word;
        endcase
    end

    ac_enc #(.L(32)) u_core (
        .clk(clk), .rst_n(rst_n), .start(core_start),
        .ld_valid(ld_valid), .ld_ready(ld_ready), .ld_word(load_word),
        .busy(), .done(core_done), .cur_layer(), .layer_done(layer_done),
        .cycles(cycles), .wait_cycles(wait_cycles), .next_free(),
        .xr_valid(state == OUTPUT_READ), .xr_addr(index), .xr_data(out_data),
        .dbg0_valid(), .dbg0_kind(), .dbg0_row(), .dbg0_idx(), .dbg0_data(),
        .dbg1_valid(), .dbg1_kind(), .dbg1_row(), .dbg1_idx(), .dbg1_data()
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            index <= 0;
            parameter_layer <= 0;
            beat <= 0;
            pending_data <= 0;
            pending <= 0;
            core_start <= 0;
            core_done_seen <= 0;
            layers_completed <= 0;
            done <= 0;
        end else begin
            done <= 0;
            core_start <= 0;
            if (layer_done) layers_completed <= layers_completed + 1'b1;
            if (core_done) core_done_seen <= 1;

            if (in_valid && in_ready) begin
                pending_data <= in_data;
                pending <= 1;
            end

            if (ld_valid && ld_ready) begin
                if (!load_last) beat <= beat + 1'b1;
                else begin
                    pending <= 0;
                    beat <= 0;
                    index <= index + 1'b1;
                    case (state)
                        INPUT_WORDS: if (index == LAST_INPUT) begin
                            index <= 0;
                            state <= GELU_WORDS;
                        end
                        GELU_WORDS: if (index == LAST_TABLE) begin
                            index <= 0;
                            state <= EXP_WORDS;
                        end
                        EXP_WORDS: if (index == LAST_TABLE) begin
                            index <= 0;
                            state <= PARAM_WORDS;
                            core_start <= 1;
                        end
                        PARAM_WORDS: if (index == LAST_PARAM) begin
                            index <= 0;
                            parameter_layer <= parameter_layer + 1'b1;
                            if (parameter_layer == 4'd11) state <= WAIT_CORE;
                        end
                        default: ;
                    endcase
                end
            end

            case (state)
                IDLE: if (start) begin
                    state <= INPUT_WORDS;
                    index <= 0;
                    parameter_layer <= 0;
                    layers_completed <= 0;
                    core_done_seen <= 0;
                end
                WAIT_CORE: if (core_done_seen) state <= OUTPUT_READ;
                OUTPUT_READ: state <= OUTPUT_WORD;
                OUTPUT_WORD: if (out_ready) begin
                    if (index == LAST_INPUT) begin
                        state <= IDLE;
                        done <= 1;
                    end else begin
                        index <= index + 1'b1;
                        state <= OUTPUT_READ;
                    end
                end
                default: ;
            endcase
        end
    end

`ifndef SYNTHESIS
    // 全部编码层都完成后才允许读回最终激活。
    always @(posedge clk) if (rst_n && out_valid && layers_completed != 4'd12)
        $fatal(1, "完整输出开始时编码层数错误");
`endif
endmodule

`default_nettype wire
