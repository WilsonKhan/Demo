`timescale 1ns/1ps
`default_nettype none

module led_centroid_tb;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n = 1'b0;

    logic frame_start = 1'b0;
    logic frame_end = 1'b0;
    logic pixel_valid = 1'b0;
    logic is_red = 1'b0;

    logic [9:0] pixel_x = 10'd0;
    logic [9:0] pixel_y = 10'd0;

    logic frame_done;
    logic target_valid;
    logic [9:0] target_x;
    logic [9:0] target_y;
    logic [31:0] red_count;

    int checks = 0;

    // Use three pixels to make the unit tests compact.
    // Production configuration defaults to 20 pixels.

    led_centroid #(
        .MIN_PIXELS(32'd3)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .frame_start(frame_start),
        .frame_end(frame_end),

        .pixel_valid(pixel_valid),
        .is_red(is_red),
        .pixel_x(pixel_x),
        .pixel_y(pixel_y),

        .frame_done(frame_done),
        .target_valid(target_valid),
        .target_x(target_x),
        .target_y(target_y),
        .red_count(red_count)
    );

    task automatic send_pixel(
        input bit start,
        input bit finish,
        input bit valid,
        input bit red,
        input logic [9:0] x,
        input logic [9:0] y
    );
        @(negedge clk);

        frame_start = start;
        frame_end   = finish;
        pixel_valid = valid;
        is_red      = red;
        pixel_x     = x;
        pixel_y     = y;

        @(posedge clk);
        #1;
    endtask

    task automatic check_result(
        input string name,
        input bit expected_valid,
        input logic [9:0] expected_x,
        input logic [9:0] expected_y,
        input logic [31:0] expected_count
    );

        if (frame_done !== 1'b1)
            $fatal(1,
                "FAIL %s: frame_done must pulse at frame completion",
                name
            );

        if (target_valid !== expected_valid ||
            target_x !== expected_x ||
            target_y !== expected_y ||
            red_count !== expected_count)
            $fatal(1,
                "FAIL %s: valid=%b x=%0d y=%0d count=%0d; expected valid=%b x=%0d y=%0d count=%0d",
                name,
                target_valid, target_x, target_y, red_count,
                expected_valid, expected_x, expected_y, expected_count
            );

        checks++;
        $display("PASS [%0d]: %s", checks, name);
    endtask

    task automatic check_pulses_clear(
        input string name
    );
        send_pixel(0, 0, 0, 0, 0, 0);

        if (frame_done !== 1'b0 ||
            target_valid !== 1'b0)
            $fatal(1,
                "FAIL %s: frame_done=%b target_valid=%b",
                name, frame_done, target_valid
            );

        checks++;
        $display("PASS [%0d]: %s", checks, name);
    endtask

    initial begin

        $dumpfile("led_centroid.vcd");
        $dumpvars(0, led_centroid_tb);

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // Test 1: centroid calculation.
        send_pixel(1, 0, 1, 1, 10, 20);
        send_pixel(0, 0, 1, 1, 20, 30);
        send_pixel(0, 1, 1, 1, 30, 40);

        check_result(
            "three-pixel centroid",
            1, 20, 30, 3
        );

        // Test 2: frame_done and target_valid are pulses.
        check_pulses_clear("valid-frame pulses clear");

        // Test 3: reject a frame with two pixels.
        send_pixel(1, 0, 1, 1, 100, 100);
        send_pixel(0, 1, 1, 1, 200, 200);

        check_result(
            "two pixels rejected",
            0, 0, 0, 2
        );

        // Test 4: frame_done still pulses for rejected frames.
        check_pulses_clear("rejected-frame pulse clears");

        // Test 5: invalid and non-red pixels ignored.
        send_pixel(1, 0, 1, 0, 400, 400);
        send_pixel(0, 0, 0, 1, 400, 400);
        send_pixel(0, 1, 1, 0, 400, 400);

        check_result(
            "zero red pixels",
            0, 0, 0, 0
        );

        // Test 6: integer division rounds down.
        send_pixel(1, 0, 1, 1, 10, 20);
        send_pixel(0, 0, 1, 1, 11, 21);
        send_pixel(0, 1, 1, 1, 12, 21);

        check_result(
            "integer centroid rounding",
            1, 11, 20, 3
        );

        // Test 7: coordinates at image boundary.
        send_pixel(1, 0, 1, 1, 639, 479);
        send_pixel(0, 0, 1, 1, 639, 479);
        send_pixel(0, 1, 1, 1, 639, 479);

        check_result(
            "image boundary",
            1, 639, 479, 3
        );

        // Test 8: reset must clear all outputs.
        send_pixel(1, 0, 1, 1, 500, 400);
        send_pixel(0, 0, 1, 1, 500, 400);

        @(negedge clk);
        rst_n = 1'b0;
        #1;

        if (frame_done !== 1'b0 ||
            target_valid !== 1'b0 ||
            target_x !== 10'd0 ||
            target_y !== 10'd0 ||
            red_count !== 32'd0)
            $fatal(1, "FAIL: reset did not clear outputs");

        checks++;
        $display("PASS [%0d]: reset clears outputs", checks);

        frame_start = 0;
        frame_end = 0;
        pixel_valid = 0;
        is_red = 0;

        @(negedge clk);
        rst_n = 1'b1;

        // Test 9: old partial pixels must not contribute.
        send_pixel(1, 0, 1, 1, 25, 35);
        send_pixel(0, 0, 1, 1, 25, 35);
        send_pixel(0, 1, 1, 1, 25, 35);

        check_result(
            "reset discards partial frame",
            1, 25, 35, 3
        );

        // Test 10: empty frame after a valid frame.
        send_pixel(1, 1, 0, 0, 0, 0);

        check_result(
            "empty frame clears target",
            0, 0, 0, 0
        );

        // Test 11: empty-frame pulse clears.
        check_pulses_clear("empty-frame pulse clears");

        $display("---------------------------------------");
        $display("PASS: led_centroid_tb (%0d checks)", checks);
        $display("---------------------------------------");

        $finish;
    end

endmodule

`default_nettype wire
