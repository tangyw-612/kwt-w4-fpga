`default_nettype none
module mac_uart_frame (
    input wire clk, rst_n,
    input wire rx_valid, rx_error,
    input wire [7:0] rx_data,
    output wire tx_valid,
    output wire [7:0] tx_data,
    input wire tx_ready,
    output wire mac_start,
    output logic [7:0] mac_command,
    output wire rejected,
    output wire [15:0] rejected_sample,
    input wire mac_busy, mac_done, mac_pass,
    input wire [1:0] mac_matches,
    input wire [31:0] mac_cycles, dot0, dot1
);
    localparam [7:0] REQUEST = 8'hA5, RESPONSE = 8'h5A, VERSION = 8'h01;
    localparam [7:0] PASS = 0, FAIL = 1, UNSUPPORTED = 2, PONG = 8'h10;
    typedef enum logic [2:0] {IDLE, RECEIVE, DISPATCH, WAIT_MAC, PACK, SEND} state_t;
    state_t state;
    logic [2:0] rx_index;
    logic [15:0] sample, token, idle_ticks;
    logic [7:0] rx_checksum, result_status, checksum;
    logic legacy;
    logic [7:0] legacy_command;
    logic [4:0] tx_index;
    logic [159:0] response;
    wire mac_result = result_status == PASS || result_status == FAIL;
    wire supported;

    always_comb begin
        if (legacy) mac_command = legacy_command;
        else begin
            case (sample)
                16'd100: mac_command = "U";
                16'd200: mac_command = "L";
                16'd250: mac_command = "R";
                16'd400: mac_command = "S";
                default: mac_command = 0;
            endcase
        end
    end

    assign supported = mac_command != 0;
    assign mac_start = state == DISPATCH && supported && !mac_busy && !mac_done;
    assign rejected = state == PACK && !legacy && result_status == UNSUPPORTED;
    assign rejected_sample = sample;
    assign tx_valid = state == SEND;
    assign tx_data = tx_index == 20 ? checksum : response[8*tx_index +: 8];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            rx_index <= 0;
            rx_checksum <= 0;
            sample <= 0;
            token <= 0;
            idle_ticks <= 0;
            result_status <= 0;
            legacy <= 0;
            legacy_command <= 0;
            response <= 0;
            checksum <= 0;
            tx_index <= 0;
        end else begin
            case (state)
                IDLE: if (rx_valid) begin
                    if (rx_data == REQUEST) begin
                        legacy <= 0;
                        rx_index <= 0;
                        rx_checksum <= REQUEST;
                        idle_ticks <= 0;
                        state <= RECEIVE;
                    end else if (rx_data == "R" || rx_data == "U" || rx_data == "L" || rx_data == "S") begin
                        // 继续接受原小车程序的方向字节和单字节回执。
                        legacy <= 1;
                        legacy_command <= rx_data;
                        state <= DISPATCH;
                    end
                end
                RECEIVE: begin
                    // 坏帧或截断帧丢弃，约 2 毫秒后可重新接收帧头。
                    if (rx_error || &idle_ticks) state <= IDLE;
                    else if (rx_valid) begin
                        idle_ticks <= 0;
                        rx_checksum <= rx_checksum ^ rx_data;
                        rx_index <= rx_index + 1'b1;
                        case (rx_index)
                            0: token[7:0] <= rx_data;
                            1: token[15:8] <= rx_data;
                            2: sample[7:0] <= rx_data;
                            3: sample[15:8] <= rx_data;
                            4: state <= rx_checksum == rx_data ? DISPATCH : IDLE;
                            default: state <= IDLE;
                        endcase
                    end else idle_ticks <= idle_ticks + 1'b1;
                end
                DISPATCH: begin
                    if (!supported) begin
                        result_status <= sample == 16'hFFFF ? PONG : UNSUPPORTED;
                        state <= PACK;
                    end else if (mac_start) state <= WAIT_MAC;
                end
                WAIT_MAC: if (mac_done) begin
                    result_status <= mac_pass ? PASS : FAIL;
                    state <= PACK;
                end
                PACK: begin
                    // 多字节字段按小端发送。非计算请求的结果字段为零。
                    if (legacy) response <= {152'd0, result_status == PASS ? 8'h50 : 8'h46};
                    else response <= {mac_result ? dot1 : 32'd0, mac_result ? dot0 : 32'd0,
                                      mac_result ? mac_cycles : 32'd0, mac_result ? {6'd0, mac_matches} : 8'd0,
                                      result_status, sample, token, VERSION, RESPONSE};
                    tx_index <= 0;
                    checksum <= 0;
                    state <= SEND;
                end
                SEND: if (tx_ready) begin
                    if (legacy || tx_index == 20) state <= IDLE;
                    else begin
                        checksum <= checksum ^ tx_data;
                        tx_index <= tx_index + 1'b1;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
