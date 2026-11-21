`default_nettype none
module encoder_uart_demo #(
    parameter int INPUT_WORDS = 100174,
    parameter int OUTPUT_WORDS = 6336,
    parameter int BLOCK_WORDS = 256,
    parameter int TIMEOUT_CLOCKS = 100000000,
    parameter bit LIVE_CLASSIFIER = 0
)(
    input wire clk, rst_n, key_pressed,
    input wire rx_valid, rx_error,
    input wire [7:0] rx_data,
    output logic tx_valid,
    output logic [7:0] tx_data,
    input wire tx_ready,
    output wire running,
    output logic accepted, result_valid, check_pass,
    output logic [1:0] direction,
    output logic [31:0] cycles,
    output wire [3:0] layers_completed,
    input wire live_start,
    output wire engine_idle, live_done, live_ok,
    output wire [3:0] live_class,
    output logic [31:0] wait_cycles
);
    typedef enum logic [3:0] {
        IDLE, PREPARE, BEGIN_CORE, CREDIT, RECEIVE_BYTES, READ_WORD, FEED_WORD,
        WAIT_OUTPUT, HEADER, TAKE_OUTPUT, SEND_WORD, SEND_STATUS, VERIFY, ABORT_TASK,
        LIVE_DRAIN, LIVE_NOTIFY
    } state_t;
    state_t state, next_state;
    localparam int ADDR_W = $clog2(BLOCK_WORDS);
    localparam int REMAIN_W = $clog2(INPUT_WORDS+1);
    localparam int TIMEOUT_W = $clog2(TIMEOUT_CLOCKS+1);
    localparam int OUT_W = $clog2(OUTPUT_WORDS+1);

    logic [REMAIN_W-1:0] remaining;
    wire [ADDR_W:0] block_length = remaining > BLOCK_WORDS ? (ADDR_W+1)'(BLOCK_WORDS) : (ADDR_W+1)'(remaining);
    logic [ADDR_W-1:0] word_ptr;
    wire last_in_block = {1'b0, word_ptr} == block_length - 1'b1;
    logic [1:0] byte_ptr;
    logic [23:0] partial_word;
    logic [31:0] out_word;
    logic [OUT_W-1:0] output_index;
    logic [3:0] status_index;
    logic [TIMEOUT_W-1:0] timeout_count;
    logic [3:0] reported_layers;
    logic live_task;

    logic core_active;
    wire core_reset_n = rst_n && core_active;
    wire core_in_ready, core_out_valid;
    wire [31:0] core_out_data, core_cycles, core_wait_cycles;
    wire [3:0] core_layers;
    (* ram_style = "block" *) logic [31:0] receive_buffer [0:BLOCK_WORDS-1];
    logic [31:0] input_word;

    // 上位机收到 G 才发送一块，核心可对块内的任意字施加反压。
    always_ff @(posedge clk) begin
        if (state == RECEIVE_BYTES && rx_valid && byte_ptr == 3)
            receive_buffer[word_ptr] <= {rx_data, partial_word};
        if (state == READ_WORD) input_word <= receive_buffer[word_ptr];
    end

    w4_full_stream u_encoder (
        .clk(clk), .rst_n(core_reset_n), .start(state == BEGIN_CORE),
        .in_valid(state == FEED_WORD), .in_data(input_word), .in_ready(core_in_ready),
        .out_valid(core_out_valid), .out_data(core_out_data),
        .out_ready(state == TAKE_OUTPUT || state == LIVE_DRAIN),
        .busy(), .done(), .layers_completed(core_layers), .cycles(core_cycles), .wait_cycles(core_wait_cycles)
    );

    wire head_valid;
    if (LIVE_CLASSIFIER) begin : g_classifier
        w4_cls_head u_head (
            .clk(clk), .rst_n(rst_n), .clear(state == PREPARE),
            .cls_write(state == LIVE_DRAIN && core_out_valid && output_index < 64),
            .cls_index(output_index[5:0]), .cls_data(core_out_data), .valid(head_valid), .class_id(live_class)
        );
    end else begin : g_no_classifier
        assign {head_valid, live_class} = 0;
    end
    assign engine_idle = state == IDLE;
    assign live_done = live_task && (state == LIVE_NOTIFY || state == ABORT_TASK);
    assign live_ok = state == LIVE_NOTIFY && head_valid && reported_layers == 12;
    assign running = state != IDLE && state != VERIFY && state != ABORT_TASK && state != LIVE_NOTIFY;
    assign layers_completed = running ? core_layers : reported_layers;
    logic [1:0] decoded_direction;
    logic decoded_valid;
    always_comb begin
        decoded_valid = 1;
        case (rx_data)
            "R": decoded_direction = 0;
            "U": decoded_direction = 1;
            "L": decoded_direction = 2;
            "S": decoded_direction = 3;
            default: begin decoded_direction = 0; decoded_valid = 0; end
        endcase
    end

    always_comb begin
        next_state = state;
        tx_valid = 0;
        tx_data = 0;
        case (state)
            IDLE: if ((LIVE_CLASSIFIER && live_start) || (rx_valid && rx_data == "F")) next_state = PREPARE;
            PREPARE: next_state = BEGIN_CORE;
            BEGIN_CORE: next_state = CREDIT;
            CREDIT: begin
                tx_valid = 1;
                tx_data = "G";
                if (tx_ready) next_state = RECEIVE_BYTES;
            end
            RECEIVE_BYTES: if (rx_valid && byte_ptr == 3 && last_in_block) next_state = READ_WORD;
            READ_WORD: next_state = FEED_WORD;
            FEED_WORD: if (core_in_ready) begin
                if (!last_in_block) next_state = READ_WORD;
                else next_state = remaining == REMAIN_W'(block_length) ? WAIT_OUTPUT : CREDIT;
            end
            WAIT_OUTPUT: if (core_out_valid) next_state = live_task ? LIVE_DRAIN : HEADER;
            LIVE_DRAIN: if (core_out_valid && output_index == OUTPUT_WORDS - 1) next_state = LIVE_NOTIFY;
            LIVE_NOTIFY: next_state = IDLE;
            HEADER: begin
                tx_valid = 1;
                tx_data = "D";
                if (tx_ready) next_state = TAKE_OUTPUT;
            end
            TAKE_OUTPUT: if (core_out_valid) next_state = SEND_WORD;
            SEND_WORD: begin
                tx_valid = 1;
                tx_data = out_word[byte_ptr*8 +: 8];
                if (tx_ready && byte_ptr == 3)
                    next_state = output_index == OUTPUT_WORDS - 1 ? SEND_STATUS : TAKE_OUTPUT;
            end
            SEND_STATUS: begin
                tx_valid = 1;
                // 共九个字节，使用小端顺序发送周期、等待周期和层数。
                if (status_index < 4) tx_data = cycles[status_index[1:0]*8 +: 8];
                else if (status_index < 8) tx_data = wait_cycles[status_index[1:0]*8 +: 8];
                else tx_data = {4'b0, reported_layers};
                if (tx_ready && status_index == 8) next_state = VERIFY;
            end
            VERIFY: if (rx_valid && (decoded_valid || rx_data == "N")) next_state = IDLE;
            ABORT_TASK: begin
                tx_valid = !live_task;
                tx_data = "E";
                if (live_task || tx_ready) next_state = IDLE;
            end
            default: next_state = IDLE;
        endcase
        if (state != IDLE && state != ABORT_TASK && (key_pressed || rx_error || timeout_count == TIMEOUT_CLOCKS - 1))
            next_state = ABORT_TASK;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            core_active <= 0;
            remaining <= 0;
            word_ptr <= 0;
            byte_ptr <= 0;
            output_index <= 0;
            status_index <= 0;
            partial_word <= 0;
            out_word <= 0;
            cycles <= 0;
            wait_cycles <= 0;
            reported_layers <= 0;
            timeout_count <= 0;
            accepted <= 0;
            result_valid <= 0;
            check_pass <= 0;
            direction <= 0;
            live_task <= 0;
        end else begin
            state <= next_state;
            if (next_state == ABORT_TASK || next_state == IDLE) core_active <= 0;
            else if (state == PREPARE) core_active <= 1;
            accepted <= 0;
            if (state == IDLE || state != next_state || rx_valid || (tx_valid && tx_ready)) timeout_count <= 0;
            else timeout_count <= timeout_count + 1'b1;

            case (state)
                IDLE: if (next_state == PREPARE) live_task <= LIVE_CLASSIFIER && live_start;
                PREPARE: begin
                    remaining <= REMAIN_W'(INPUT_WORDS);
                    word_ptr <= 0;
                    byte_ptr <= 0;
                    output_index <= 0;
                    status_index <= 0;
                    reported_layers <= 0;
                    cycles <= 0;
                    wait_cycles <= 0;
                    result_valid <= 0;
                    check_pass <= 0;
                end
                RECEIVE_BYTES: if (rx_valid) begin
                    byte_ptr <= byte_ptr + 1'b1;
                    if (byte_ptr == 3) word_ptr <= last_in_block ? '0 : word_ptr + 1'b1;
                    else partial_word[byte_ptr*8 +: 8] <= rx_data;
                end
                FEED_WORD: if (core_in_ready) begin
                    word_ptr <= last_in_block ? '0 : word_ptr + 1'b1;
                    if (last_in_block) remaining <= remaining - REMAIN_W'(block_length);
                end
                TAKE_OUTPUT: if (core_out_valid) out_word <= core_out_data;
                SEND_WORD: if (tx_ready) begin
                    byte_ptr <= byte_ptr + 1'b1;
                    if (byte_ptr == 3) begin
                        output_index <= output_index + 1'b1;
                        if (output_index == OUTPUT_WORDS - 1) begin
                            cycles <= core_cycles;
                            wait_cycles <= core_wait_cycles;
                            reported_layers <= core_layers;
                        end
                    end
                end
                SEND_STATUS: if (tx_ready) status_index <= status_index + 1'b1;
                LIVE_DRAIN: if (core_out_valid) begin
                    output_index <= output_index + 1'b1;
                    if (output_index == OUTPUT_WORDS - 1) begin
                        cycles <= core_cycles;
                        wait_cycles <= core_wait_cycles;
                        reported_layers <= core_layers;
                    end
                end
                LIVE_NOTIFY: begin
                    result_valid <= 1;
                    check_pass <= live_ok;
                end
                VERIFY: if (rx_valid && (decoded_valid || rx_data == "N")) begin
                    result_valid <= 1;
                    check_pass <= decoded_valid && layers_completed == 12;
                    accepted <= decoded_valid && layers_completed == 12;
                    if (decoded_valid) direction <= decoded_direction;
                end
                ABORT_TASK: begin result_valid <= 1; check_pass <= 0; end
                default: begin end
            endcase
        end
    end
endmodule
`default_nettype wire
