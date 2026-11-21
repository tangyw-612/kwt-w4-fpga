`default_nettype none

module keyword_live_uart (
    input wire clk, rst_n, rx_valid, rx_error, tx_ready,
    input wire [7:0] rx_data,
    output logic tx_valid,
    output logic [7:0] tx_data,
    output wire core_rx_valid, core_rx_error, core_tx_ready,
    input wire core_tx_valid, core_idle, core_done, core_ok,
    input wire [7:0] core_tx_data,
    input wire [3:0] core_class, core_layers,
    input wire [31:0] core_cycles, core_wait,
    output logic start,
    output logic [9:0] sample_id,
    output logic [127:0] wave,
    output logic [1:0] display_status,
    output logic [3:0] display_class,
    output logic [31:0] display_cycles
);
    typedef enum logic [2:0] {IDLE, REQUEST, COMPUTE, REPLY, PROBE} state_t;
    state_t state;
    logic [4:0] index;
    logic [18:0] header_timeout;
    logic [7:0] request_xor, reply_xor;
    logic [15:0] token, request_sample;
    logic [127:0] request_wave;
    logic [111:0] reply_body;
    wire pass_uart = state == COMPUTE || (state == IDLE && !core_idle);
    assign core_tx_ready = tx_ready && pass_uart;
    assign core_rx_valid = rx_valid && (pass_uart || (state == IDLE && rx_data == "F"));
    assign core_rx_error = rx_error && pass_uart;

    always_comb begin
        tx_valid = pass_uart && core_tx_valid;
        tx_data = core_tx_data;
        if (state == PROBE) begin
            tx_valid = 1;
            case (index[1:0])
                0: tx_data = "K";
                1: tx_data = "4";
                2: tx_data = "F";
                3: tx_data = "1";
            endcase
        end else if (state == REPLY) begin
            tx_valid = 1;
            if (index == 0) tx_data = "R";
            else if (index == 15) tx_data = reply_xor;
            else tx_data = reply_body[(index-1)*8 +: 8];
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            index <= 0;
            request_xor <= 0;
            reply_xor <= 0;
            header_timeout <= 0;
            token <= 0;
            request_sample <= 0;
            request_wave <= 0;
            reply_body <= 0;
            start <= 0;
            sample_id <= 0;
            wave <= 0;
            display_status <= 0;
            display_class <= 0;
            display_cycles <= 0;
        end else begin
            start <= 0;
            case (state)
                IDLE: if (core_idle && rx_valid) begin
                    index <= 0;
                    if (rx_data == "I") state <= PROBE;
                    if (rx_data == "K") begin
                        state <= REQUEST;
                        header_timeout <= 0;
                        request_xor <= "K";
                    end
                end
                REQUEST: begin
                    // 小端事务号和样本号后接波形。波形仅用于显示，不进入计算链路。
                    if (rx_error || &header_timeout) state <= IDLE;
                    else if (rx_valid) begin
                        header_timeout <= 0;
                        index <= index + 1'b1;
                        request_xor <= request_xor ^ rx_data;
                        case (index)
                            0, 1: token[index[0]*8 +: 8] <= rx_data;
                            2, 3: request_sample[index[0]*8 +: 8] <= rx_data;
                            20: begin
                                state <= IDLE;
                                if (rx_data == request_xor && request_sample < 600) begin
                                    state <= COMPUTE;
                                    start <= 1;
                                    sample_id <= request_sample[9:0];
                                    wave <= request_wave;
                                    display_status <= 1;
                                end
                            end
                            default: request_wave[(index-4)*8 +: 8] <= rx_data;
                        endcase
                    end else header_timeout <= header_timeout + 1'b1;
                end
                COMPUTE: if (core_done) begin
                    display_status <= core_ok ? 2 : 3;
                    display_class <= core_class;
                    display_cycles <= core_cycles - core_wait;
                    reply_body <= {core_wait, core_cycles, 4'd0, core_layers,
                                   core_ok ? {4'd0, core_class} : 8'hff, request_sample, token};
                    index <= 0;
                    reply_xor <= 0;
                    state <= REPLY;
                end
                REPLY: if (tx_ready) begin
                    index <= index + 1'b1;
                    reply_xor <= reply_xor ^ tx_data;
                    if (index == 15) state <= IDLE;
                end
                PROBE: if (tx_ready) begin
                    index <= index + 1'b1;
                    if (index == 3) state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
