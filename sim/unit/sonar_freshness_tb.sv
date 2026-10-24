`timescale 1ns/1ps
`default_nettype none

module sonar_freshness_tb;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n = 1'b0;
    logic measurement_valid = 1'b0;
    logic [15:0] measurement_mm = 16'd0;

    logic sonar_valid;
    logic [15:0] distance_mm;

    int checks = 0;

    sonar_freshness #(
        .MAX_AGE_CYCLES(4),
        .MIN_RANGE_MM(16'd20),
        .MAX_RANGE_MM(16'd3500)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .measurement_valid(measurement_valid),
        .measurement_mm(measurement_mm),
        .sonar_valid(sonar_valid),
        .distance_mm(distance_mm)
    );

    task automatic tick;
        @(posedge clk);
        #1;
    endtask

    task automatic send_measurement(
        input logic [15:0] distance
    );
        @(negedge clk);
        measurement_valid = 1'b1;
        measurement_mm = distance;

        tick();

        @(negedge clk);
        measurement_valid = 1'b0;
    endtask

    task automatic check_state(
        input string name,
        input bit expected_valid,
        input logic [15:0] expected_distance
    );
        if (sonar_valid !== expected_valid ||
            distance_mm !== expected_distance) begin
            $fatal(1,
                "FAIL %s: sonar_valid=%b distance=%0d expected=%b/%0d",
                name, sonar_valid, distance_mm,
                expected_valid, expected_distance
            );
        end

        checks++;
        $display("PASS [%0d]: %s", checks, name);
    endtask

    initial begin
        $dumpfile("sonar_freshness.vcd");
        $dumpvars(0, sonar_freshness_tb);

        repeat (3) @(negedge clk);

        check_state("reset starts invalid", 0, 0);

        rst_n = 1'b1;

        send_measurement(16'd1000);
        check_state("valid 1000 mm measurement", 1, 1000);

        tick();
        check_state("reading persists after one cycle", 1, 1000);

        tick();
        check_state("reading persists after two cycles", 1, 1000);

        // A new measurement refreshes the watchdog.
        send_measurement(16'd500);
        check_state("new reading refreshes distance", 1, 500);

        // Count from the last valid measurement.
        repeat (3) tick();
        check_state("reading valid before expiry", 1, 500);

        tick();
        check_state("stale reading expires", 0, 0);

        repeat (3) tick();
        check_state("expired reading remains invalid", 0, 0);

        // Restore a valid reading.
        send_measurement(16'd250);
        check_state("valid reading after expiry", 1, 250);

        // Zero is not an acceptable distance.
        send_measurement(16'd0);
        check_state("zero measurement rejected", 0, 0);

        // Boundary of accepted measurement range.
        send_measurement(16'd20);
        check_state("minimum range accepted", 1, 20);

        send_measurement(16'd3500);
        check_state("maximum range accepted", 1, 3500);

        send_measurement(16'd19);
        check_state("below minimum range rejected", 0, 0);

        send_measurement(16'd3501);
        check_state("above maximum range rejected", 0, 0);

        // The Ed sonar driver represents timeout/no object
        // using a saturated distance of 4000 mm.
        send_measurement(16'd4000);
        check_state("4000 mm timeout rejected", 0, 0);

        // A valid reading should not survive an invalid update.
        send_measurement(16'd900);
        check_state("fresh reading restored", 1, 900);

        send_measurement(16'd4000);
        check_state("invalid update clears old reading", 0, 0);

        // Present a distance change without a valid pulse.
        @(negedge clk);
        measurement_mm = 16'd1200;
        measurement_valid = 1'b0;

        tick();
        check_state("distance ignored without valid pulse", 0, 0);

        // Test asynchronous reset.
        send_measurement(16'd600);
        check_state("reading before reset", 1, 600);

        @(negedge clk);
        rst_n = 1'b0;
        #1;

        check_state("reset clears valid reading", 0, 0);

        $display("-----------------------------------------");
        $display("PASS: sonar_freshness_tb (%0d checks)", checks);
        $display("-----------------------------------------");

        $finish;
    end

endmodule

`default_nettype wire
