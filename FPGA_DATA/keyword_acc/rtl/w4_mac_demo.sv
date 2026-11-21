`default_nettype none
module w4_mac_demo (
    input  wire clk, rst_n, start,
    input  wire [1:0] command,
    output wire busy,
    output logic done, pass,
    output logic [1:0] result_command, match_count,
    output logic [31:0] result0, result1,
    output logic [7:0] cycles
);
    typedef enum logic [2:0] {IDLE, FEED, SETTLE, DRAIN0, DRAIN1, RESULTS} state_t;
    state_t state;
    logic [79:0] vectors [0:127];
    logic [63:0] expected [0:3];
    initial begin
        $readmemh("mac_vectors.mem", vectors);
        $readmemh("mac_expected.mem", expected);
    end

    logic [79:0] operands;
    logic [4:0] pair_index;
    logic [2:0] settle_count;
    logic pair_valid, pair_first, pair_last, second_result, lane0_equal;
    wire output_valid;
    wire [31:0] output_data;
    wire [63:0] reference = expected[result_command];
    wire second_match = output_data == reference[63:32];
    assign busy = state != IDLE;

    // 保底版只保留 W4 投影的双项归约和 44 位累加，结果为缩放与偏置前的原始点积。
    w4_projection_pair u_mac (
        .clk(clk), .rst_n(rst_n), .pair_valid(pair_valid), .pair_first(pair_first),
        .pair_last(pair_last), .activation0(operands[31:0]), .activation1(operands[63:32]),
        .codes(operands[79:64]), .drain_valid(state == DRAIN0 || state == DRAIN1),
        .drain_lane(state == DRAIN1), .output_valid(output_valid), .output_value(output_data)
    );

    always_ff @(posedge clk) begin
        if (state == FEED) operands <= vectors[{result_command, pair_index}];
        pair_valid <= rst_n && state == FEED;
        pair_first <= pair_index == 0;
        pair_last <= pair_index == 31;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            done <= 0;
            pass <= 0;
            match_count <= 0;
            result_command <= 0;
            result0 <= 0;
            result1 <= 0;
            cycles <= 0;
            pair_index <= 0;
            settle_count <= 0;
            second_result <= 0;
            lane0_equal <= 0;
        end else begin
            done <= 0;
            if (busy) cycles <= cycles + 1'b1;
            case (state)
                IDLE: if (start) begin
                    result_command <= command;
                    cycles <= 0;
                    pair_index <= 0;
                    second_result <= 0;
                    state <= FEED;
                end
                FEED: if (pair_index == 31) begin
                    settle_count <= 4;
                    state <= SETTLE;
                end else pair_index <= pair_index + 1'b1;
                SETTLE: if (settle_count == 0) state <= DRAIN0;
                        else settle_count <= settle_count - 1'b1;
                DRAIN0: state <= DRAIN1;
                DRAIN1: state <= RESULTS;
                RESULTS: if (output_valid) begin
                    if (!second_result) begin
                        result0 <= output_data;
                        lane0_equal <= output_data == reference[31:0];
                        second_result <= 1;
                    end else begin
                        result1 <= output_data;
                        pass <= lane0_equal && second_match;
                        match_count <= {1'b0, lane0_equal} + {1'b0, second_match};
                        done <= 1;
                        state <= IDLE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
