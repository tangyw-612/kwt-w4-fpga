`default_nettype none

module w4_cls_head (
    input wire clk, rst_n, clear,
    input wire cls_write,
    input wire [5:0] cls_index,
    input wire signed [31:0] cls_data,
    output logic valid,
    output logic [3:0] class_id
);
    typedef enum logic [2:0] {COLLECT, SEED, READ_COEF, MULTIPLY, ADD, COMPARE} state_t;
    state_t state;
    (* ram_style = "distributed" *) logic signed [31:0] activation [0:63];
    (* rom_style = "block" *) logic signed [23:0] weight [0:767];
    logic signed [63:0] bias [0:11];
    logic [5:0] column;
    logic [3:0] category;
    logic signed [31:0] feature_q;
    logic signed [23:0] weight_q;
    logic signed [55:0] product_q;
    logic signed [63:0] total, best;

    initial begin
        $readmemh("w4_cls_weights.mem", weight);
        $readmemh("w4_cls_bias.mem", bias);
    end

    always_ff @(posedge clk) begin
        if (state == COLLECT && cls_write) activation[cls_index] <= cls_data;
        if (state == READ_COEF) begin
            feature_q <= activation[column];
            weight_q <= weight[{category, column}];
        end
        if (state == MULTIPLY) product_q <= feature_q * weight_q;
    end

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            state <= COLLECT;
            valid <= 0;
            class_id <= 0;
            category <= 0;
            column <= 0;
            total <= 0;
            best <= 0;
        end else begin
            case (state)
                COLLECT: if (cls_write && cls_index == 63) state <= SEED;
                SEED: begin
                    total <= bias[category];
                    column <= 0;
                    state <= READ_COEF;
                end
                READ_COEF: state <= MULTIPLY;
                MULTIPLY: state <= ADD;
                ADD: begin
                    total <= total + {{8{product_q[55]}}, product_q};
                    column <= column + 1'b1;
                    state <= column == 63 ? COMPARE : READ_COEF;
                end
                COMPARE: begin
                    // 分数相同时保留提交版类别顺序中的第一个。
                    if (category == 0 || total > best) begin
                        best <= total;
                        class_id <= category;
                    end
                    if (category == 11) begin
                        valid <= 1;
                        state <= COLLECT;
                    end else begin
                        category <= category + 1'b1;
                        state <= SEED;
                    end
                end
                default: state <= COLLECT;
            endcase
        end
    end
endmodule
`default_nettype wire
