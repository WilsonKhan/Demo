`timescale 1ns/1ps
`default_nettype none

module sonar_result_cdc_tb;

    // Approximately 43.9 MHz and exactly 50 MHz.
    logic src_clk = 1'b0;
    logic dst_clk = 1'b0;

    always #11.39 src_clk = ~src_clk;
    always #10    dst_clk = ~dst_clk;

    logic rst_n = 1'b0;
    logic src_measurement_valid = 1'b0;
    logic [11:0] src_distance = 12'd0;

    wire src_ready;
    logic src_overrun;

    logic measurement_valid;
    logic [15:0] measurement_mm;

    int checks = 0;
    int received = 0;

    logic [15:0] received_mm [0:31];

    sonar_result_cdc dut (
        .src_clk(src_clk),
        .dst_clk(dst_clk),
        .rst_n(rst_n),

        .src_measurement_valid(src_measurement_valid),
        .src_distance(src_distance),

        .src_ready(src_ready),
        .src_overrun(src_overrun),

        .measurement_valid(measurement_valid),
        .measurement_mm(measurement_mm)
    );

    // Observe registered destination outputs away from
    // the destination clock's active edge.
    always @(negedge dst_clk) begin
        if (rst_n && measurement_valid) begin
            if (received >= 32)
                $fatal(1, "Receive history overflow");

            received_mm[received] = measurement_mm;
            received++;
        end
    end

    task automatic send_measurement(
        input logic [11:0] distance
    );
        wait (src_ready === 1'b1);

        @(negedge src_clk);
        src_distance = distance;
        src_measurement_valid = 1'b1;

        @(negedge src_clk);
        src_measurement_valid = 1'b0;
    endtask

    task automatic check_result(
        input string name,
        input int index,
        input logic [15:0] expected_distance
    );
        wait (received > index);

        if (received_mm[index] !== expected_distance)
            $fatal(1,
                "FAIL %s: received %0d, expected %0d",
                name, received_mm[index], expected_distance);

        checks++;
        $display("PASS [%0d]: %s", checks, name);
    endtask

    initial begin
        $dumpfile("sonar_result_cdc.vcd");
        $dumpvars(0, sonar_result_cdc_tb);

        repeat (5) @(negedge src_clk);
        rst_n = 1'b1;

        @(negedge dst_clk);

        if (!src_ready || src_overrun ||
            measurement_valid || measurement_mm != 0)
            $fatal(1, "Incorrect initial state");

        checks++;
        $display("PASS [%0d]: reset state", checks);

        send_measurement(12'd1000);
        check_result("1000 mm transfer", 0, 1000);

        send_measurement(12'd250);
        check_result("250 mm transfer", 1, 250);

        send_measurement(12'd20);
        check_result("minimum distance transfer", 2, 20);

        send_measurement(12'd3500);
        check_result("maximum normal distance", 3, 3500);

        // Invalid measurements must also cross correctly.
        send_measurement(12'd0);
        check_result("zero measurement forwarded", 4, 0);

        send_measurement(12'd4000);
        check_result("timeout value forwarded", 5, 4000);

        send_measurement(12'd4095);
        check_result("12-bit boundary", 6, 4095);

        // Consecutive measurements with proper handshake.
        for (int i = 0; i < 5; i++) begin
            send_measurement(12'(100 + 100 * i));
            check_result(
                $sformatf("sequential transfer %0d", i),
                7 + i,
                16'(100 + 100 * i)
            );
        end

        if (src_overrun)
            $fatal(1, "Unexpected normal-operation overrun");

        checks++;
        $display("PASS [%0d]: no normal overrun", checks);

        // Force a second result while the previous one
        // is still awaiting acknowledgement.
        wait (src_ready === 1'b1);

        @(negedge src_clk);
        src_distance = 12'd777;
        src_measurement_valid = 1'b1;

        @(negedge src_clk);
        src_distance = 12'd888;
        src_measurement_valid = 1'b1;

        @(negedge src_clk);
        src_measurement_valid = 1'b0;

        check_result(
            "busy transfer preserves first reading",
            12, 777
        );

        if (!src_overrun)
            $fatal(1, "Missing overrun indication");

        checks++;
        $display("PASS [%0d]: overrun detected", checks);

        // Allow handshake to settle before resetting.
        wait (src_ready === 1'b1);

        @(negedge src_clk);
        rst_n = 1'b0;
        #1;

        if (src_overrun || measurement_valid ||
            measurement_mm != 0)
            $fatal(1, "Reset failed to clear CDC outputs");

        checks++;
        $display("PASS [%0d]: reset clears CDC state", checks);

        repeat (5) @(negedge src_clk);
        rst_n = 1'b1;

        send_measurement(12'd600);
        check_result("transfer after reset", 13, 600);

        $display("----------------------------------------");
        $display("PASS: sonar_result_cdc_tb (%0d checks)", checks);
        $display("Received measurements: %0d", received);
        $display("----------------------------------------");

        $finish;
    end

    initial begin
        #100us;
        $fatal(1, "TIMEOUT: sonar CDC test stalled");
    end

endmodule

`default_nettype wire
