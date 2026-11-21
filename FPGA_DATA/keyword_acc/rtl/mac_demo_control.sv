`default_nettype none
module mac_demo_control (
    input wire clk, rst_n, key_pressed, jtag_valid,
    input wire [1:0] jtag_direction,
    input wire rx_valid,
    input wire [7:0] rx_data,
    output logic tx_valid,
    output wire [7:0] tx_data,
    input wire tx_ready,
    output wire running, accepted,
    output logic result_valid,
    output wire check_pass,
    output wire [1:0] direction, match_count,
    output wire [31:0] value0, value1, cycles
);
    logic [1:0] next_key, serial_direction;
    logic serial_command;
    wire task_done;
    wire [7:0] mac_cycles;
    wire free = !running && !task_done && !tx_valid;

    always_comb begin
        serial_command = rx_valid;
        case (rx_data)
            "R": serial_direction = 0;
            "U": serial_direction = 1;
            "L": serial_direction = 2;
            "S": serial_direction = 3;
            default: begin serial_direction = 0; serial_command = 0; end
        endcase
    end

    w4_mac_demo u_demo (
        .clk(clk), .rst_n(rst_n), .start(free && (serial_command || jtag_valid || key_pressed)),
        .command(serial_command ? serial_direction : (jtag_valid ? jtag_direction : next_key)), .busy(running),
        .done(task_done), .pass(check_pass), .result_command(direction), .match_count(match_count),
        .result0(value0), .result1(value1), .cycles(mac_cycles)
    );
    assign cycles = {24'b0, mac_cycles};
    assign accepted = task_done && check_pass;
    assign tx_data = check_pass ? "P" : "F";

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            result_valid <= 0;
            next_key <= 0;
            tx_valid <= 0;
        end else begin
            if (free && key_pressed && !serial_command && !jtag_valid) next_key <= next_key + 1'b1;
            if (tx_ready) tx_valid <= 0;
            if (task_done) begin
                result_valid <= 1;
                tx_valid <= 1;
            end
        end
    end
endmodule
`default_nettype wire
