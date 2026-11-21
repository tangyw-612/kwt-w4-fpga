`timescale 1ns/1ps
module w4_full_stream (
    input wire clk, rst_n, start, in_valid, out_ready,
    input wire [31:0] in_data,
    output wire in_ready, out_valid, busy, done,
    output wire [31:0] out_data, cycles, wait_cycles,
    output wire [3:0] layers_completed
);
    reg [2:0] received;
    reg [1:0] sent;
    reg gate, active;
    assign in_ready = active && gate;
    assign out_valid = active && received == 7;
    assign out_data = 32'h12345678 + {30'b0, sent};
    assign busy = active;
    assign done = sent == 3;
    assign layers_completed = received == 7 ? 12 : 0;
    assign cycles = 'h102;
    assign wait_cycles = 'h304;
    always @(posedge clk) begin
        if (!rst_n) begin received <= 0; sent <= 0; gate <= 0; active <= 0; end
        else begin
            gate <= !gate;
            if (start) active <= 1;
            if (in_valid && in_ready) begin
                if (in_data != 32'hfe89ab00 + received) $fatal(1,"Corrupt input word %h",in_data);
                received <= received + 1'b1;
            end
            if (out_valid && out_ready) sent <= sent + 1'b1;
        end
    end
endmodule

module tb_encoder_uart;
    reg clk = 0, rst_n = 0;
    always #15 clk = ~clk;
    reg key = 0, rx_valid = 0, rx_error = 0;
    reg [7:0] rx_data = 0;
    wire tx_valid, running, accepted, result_valid, pass;
    reg tx_ready = 0;
    wire [7:0] tx_data;
    wire [1:0] direction;
    wire [31:0] cycles;
    wire [3:0] layers;
    reg [7:0] replies [0:31];
    integer seen = 0, consumed = 0;

    encoder_uart_demo #(.INPUT_WORDS(7),.OUTPUT_WORDS(3),.BLOCK_WORDS(4),.TIMEOUT_CLOCKS(1000)) dut (
        .clk(clk), .rst_n(rst_n), .key_pressed(key), .rx_valid(rx_valid), .rx_error(rx_error), .rx_data(rx_data),
        .tx_valid(tx_valid), .tx_ready(tx_ready), .tx_data(tx_data), .running(running), .accepted(accepted),
        .result_valid(result_valid), .check_pass(pass), .direction(direction), .cycles(cycles), .layers_completed(layers)
    );

    always @(posedge clk) begin
        tx_ready <= !tx_ready;
        if (tx_valid && tx_ready) begin replies[seen] <= tx_data; seen <= seen + 1; end
    end

    task automatic send(input [7:0] value);
        @(negedge clk); rx_data = value; rx_valid = 1;
        @(negedge clk); rx_valid = 0;
    endtask
    task automatic expect_byte(input [7:0] value);
        wait(seen > consumed);
        @(negedge clk);
        if (replies[consumed] !== value) $fatal(1,"Protocol byte %0d: got %h expected %h",consumed,replies[consumed],value);
        consumed++;
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        send("F");
        expect_byte("G");
        for (int word = 0; word < 7; word++) begin
            if (word == 4) expect_byte("G");
            send(8'(word)); send(8'hab); send(8'h89); send(8'hfe);
        end
        expect_byte("D");
        for (int word = 0; word < 3; word++) begin
            expect_byte(8'(8'h78+word)); expect_byte(8'h56); expect_byte(8'h34); expect_byte(8'h12);
        end
        expect_byte(2); expect_byte(1); expect_byte(0); expect_byte(0);
        expect_byte(4); expect_byte(3); expect_byte(0); expect_byte(0); expect_byte(12);
        send("U");
        if (!accepted || !result_valid || !pass || direction != 1 || layers != 12) $fatal(1,"Display verification failed");

        send("F");
        expect_byte("G");
        @(negedge clk); rx_error = 1;
        @(negedge clk); rx_error = 0;
        expect_byte("E");
        if (running || pass) $fatal(1,"UART error did not reset task");
        $display("ENCODER_UART_PROTOCOL_PASS");
        $finish;
    end
    initial begin #100000; $fatal(1,"Protocol timed out"); end
endmodule
