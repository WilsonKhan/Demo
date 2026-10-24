`timescale 1ns/1ps
`default_nettype none

// MTRX3700 Major Project - V1
// Complete ultrasonic sensor integration test.
//
// Ed sonar_pll + sonar_range + hcsr04_model
// -> Group 26 sonar_result_cdc -> sonar_freshness
//
// Uses:
//   CLOCK_50: 50 MHz
//   Sonar PLL: approximately 43.904 MHz
//   Minimum trigger spacing: >60 ms
//   Freshness timeout: 250 ms
//
// Verifies physical echo timing through to the
// navigation-domain distance and validity signals.

module sonar_pipeline_tb;

    logic clk_50 = 1'b0;
    always #10 clk_50 = ~clk_50;

    logic rst_n = 1'b0;

    wire sonar_clk;
    wire pll_locked;

    sonar_pll u_pll (
        .refclk(clk_50),
        .rst(1'b0),
        .outclk_0(sonar_clk),
        .locked(pll_locked)
    );

    // ---------------------------------------------
    // Ed ultrasonic sensor and driver
    // ---------------------------------------------

    logic start_measure = 1'b0;

    wire trig;
    wire echo;
    wire [11:0] sonar_distance;
    wire sonar_ready;
    wire sonar_measure_valid;

    int wall_distance = 1000;
    logic object_present = 1'b1;

    int model_measurements;
    int model_errors;
    int model_notes;
    int model_last_echo_us;

    sonar_range u_sonar (
        .clk(sonar_clk),
        .start_measure(start_measure),
        .rst(!rst_n),
        .echo(echo),
        .trig(trig),
        .distance(sonar_distance),
        .ready(sonar_ready),
        .valid(sonar_measure_valid)
    );

    hcsr04_model #(
        .NAME("MTRX3700-SONAR"),
        .VERBOSE(0)
    ) u_sensor (
        .trig(trig),
        .echo(echo),
        .distance_mm(wall_distance),
        .object_present(object_present),
        .measurements(model_measurements),
        .errors(model_errors),
        .notes(model_notes),
        .last_echo_us(model_last_echo_us)
    );

    // ---------------------------------------------
    // Group 26 sonar clock-domain crossing
    // ---------------------------------------------

    wire cdc_ready;
    wire cdc_overrun;
    wire measurement_valid;
    wire [15:0] measurement_mm;

    sonar_result_cdc u_cdc (
        .src_clk(sonar_clk),
        .dst_clk(clk_50),
        .rst_n(rst_n),

        .src_measurement_valid(sonar_measure_valid),
        .src_distance(sonar_distance),

        .src_ready(cdc_ready),
        .src_overrun(cdc_overrun),

        .measurement_valid(measurement_valid),
        .measurement_mm(measurement_mm)
    );

    // ---------------------------------------------
    // Group 26 measurement freshness
    // ---------------------------------------------

    wire sonar_valid;
    wire [15:0] distance_mm;

    sonar_freshness #(
        .MAX_AGE_CYCLES(12_500_000),
        .MIN_RANGE_MM(16'd20),
        .MAX_RANGE_MM(16'd3500)
    ) u_freshness (
        .clk(clk_50),
        .rst_n(rst_n),

        .measurement_valid(measurement_valid),
        .measurement_mm(measurement_mm),

        .sonar_valid(sonar_valid),
        .distance_mm(distance_mm)
    );

    // ---------------------------------------------
    // Destination-side measurement monitor
    // ---------------------------------------------

    int received = 0;
    logic [15:0] last_measurement = 16'd0;

    always @(negedge clk_50) begin
        if (rst_n && measurement_valid) begin
            received++;
            last_measurement = measurement_mm;
        end
    end

    int checks = 0;

    task automatic pass(input string name);
        checks++;
        $display("PASS [%0d]: %s", checks, name);
    endtask

    // Trigger one actual sonar measurement.
    //
    // start_measure is held until sonar_range
    // leaves IDLE, accounting for its synchroniser.

    task automatic request_measurement(
        input int requested_distance,
        input bit present
    );
        wait (sonar_ready === 1'b1);
        wait (echo === 1'b0);

        @(negedge sonar_clk);

        wall_distance = requested_distance;
        object_present = present;
        start_measure = 1'b1;

        do begin
            @(negedge sonar_clk);
        end while (sonar_ready);

        start_measure = 1'b0;
    endtask

    task automatic check_measurement(
        input string name,
        input int requested_distance,
        input bit present,
        input int expected_distance,
        input bit expected_valid
    );
        int start_received;
        int actual;

        start_received = received;

        request_measurement(requested_distance, present);

        // Wait for actual Ed sonar output to cross CDC.
        wait (received > start_received);

        // Allow freshness to consume the transferred pulse.
        repeat (3) @(posedge clk_50);
        @(negedge clk_50);

        actual = int'(last_measurement);

        // Ed sonar timing may round down by 1 mm.
        if (actual != expected_distance &&
            actual != expected_distance - 1) begin
            $fatal(1,
                "FAIL %s: received %0d mm; expected %0d or %0d",
                name, actual, expected_distance,
                expected_distance - 1
            );
        end

        if (sonar_valid !== expected_valid)
            $fatal(1,
                "FAIL %s: sonar_valid=%b expected=%b",
                name, sonar_valid, expected_valid
            );

        if (expected_valid) begin
            if (distance_mm !== last_measurement)
                $fatal(1,
                    "FAIL %s: freshness output mismatch",
                    name
                );
        end else begin
            if (distance_mm !== 16'd0)
                $fatal(1,
                    "FAIL %s: invalid measurement not cleared",
                    name
                );
        end

        if (cdc_overrun)
            $fatal(1,
                "FAIL %s: unexpected CDC overrun",
                name
            );

        pass(name);

        $display(
            "  Ed sonar=%0d mm, CLOCK_50 distance=%0d mm, valid=%b",
            actual, distance_mm, sonar_valid
        );
    endtask

    // ---------------------------------------------
    // Main test sequence
    // ---------------------------------------------

    initial begin
        if ($test$plusargs("wave")) begin
            $dumpfile("sonar_pipeline.fst");
            $dumpvars(0, sonar_pipeline_tb);
        end

        repeat (10) @(negedge clk_50);

        rst_n = 1'b1;

        repeat (10) @(negedge clk_50);

        if (sonar_valid !== 1'b0 ||
            distance_mm !== 16'd0)
            $fatal(1, "FAIL: reset safety");

        pass("reset starts with invalid sonar");

        // Test 1: obstacle at 1000 mm.
        check_measurement(
            "1000 mm obstacle",
            1000, 1, 1000, 1
        );

        // Respect the sensor's recommended trigger interval.
        #65ms;

        // Test 2: obstacle at docking threshold.
        check_measurement(
            "250 mm docking threshold",
            250, 1, 250, 1
        );

        if (distance_mm > 16'd250)
            $fatal(1,
                "FAIL: docking threshold was not reached");

        pass("250 mm reading requests docking stop");

        #65ms;

        // Test 3: no echo / no obstacle detected.
        // Ed driver saturates to approximately 4000 mm.
        // Our freshness module must reject this reading.
        check_measurement(
            "no-object timeout",
            5000, 0, 4000, 0
        );

        #65ms;

        // Test 4: recovery after the timeout condition.
        check_measurement(
            "500 mm recovery after timeout",
            500, 1, 500, 1
        );

        // Confirm the reading remains usable shortly
        // after the measurement completes.
        #10ms;

        if (!sonar_valid)
            $fatal(1,
                "FAIL: valid sonar expired too early");

        pass("fresh measurement persists");

        // No further measurements: the 250 ms freshness
        // watchdog must invalidate the last value.
        #250ms;

        repeat (5) @(posedge clk_50);
        @(negedge clk_50);

        if (sonar_valid !== 1'b0 ||
            distance_mm !== 16'd0)
            $fatal(1,
                "FAIL: stale sonar reading not invalidated");

        pass("250 ms freshness expiry stops navigation");

        if (model_errors != 0)
            $fatal(1,
                "FAIL: sensor model reported %0d errors",
                model_errors);

        if (received != 4)
            $fatal(1,
                "FAIL: expected four CDC measurements, got %0d",
                received);

        pass("four measurements, zero model errors");

        $display("---------------------------------------");
        $display("PASS: sonar_pipeline_tb (%0d checks)", checks);
        $display("Measurements transferred: %0d", received);
        $display("Sensor model errors: %0d", model_errors);
        $display("---------------------------------------");

        $finish;
    end

    // Watchdog for stalled measurements or CDC.
    initial begin
        #650ms;
        $fatal(1, "TIMEOUT: sonar pipeline integration");
    end

endmodule

`default_nettype wire
