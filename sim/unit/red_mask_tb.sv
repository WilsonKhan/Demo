`timescale 1ns/1ps
`default_nettype none

module red_mask_tb;

    logic [15:0] pixel_rgb565;
    logic [9:0]  pixel_x;
    logic [9:0]  pixel_y;
    logic        pixel_valid;

    logic        mask_valid;
    logic        is_red;
    wire [9:0]   mask_x;
    wire [9:0]   mask_y;

    int tests_passed = 0;

    red_mask dut (
        .pixel_rgb565 (pixel_rgb565),
        .pixel_x      (pixel_x),
        .pixel_y      (pixel_y),
        .pixel_valid  (pixel_valid),
        .mask_valid   (mask_valid),
        .is_red       (is_red),
        .mask_x       (mask_x),
        .mask_y       (mask_y)
    );

    task automatic check_pixel(
        input string       name,
        input logic [15:0] rgb,
        input logic        valid,
        input logic        expected_red,
        input logic [9:0]  x,
        input logic [9:0]  y
    );
        pixel_rgb565 = rgb;
        pixel_valid  = valid;
        pixel_x      = x;
        pixel_y      = y;

        #10;

        if (is_red !== expected_red)
            $fatal(1,
                "FAIL: %s | RGB=%h expected_red=%b actual=%b",
                name, rgb, expected_red, is_red
            );

        if (mask_valid !== valid)
            $fatal(1,
                "FAIL: %s | mask_valid mismatch",
                name
            );

        if (mask_x !== x || mask_y !== y)
            $fatal(1,
                "FAIL: %s | coordinate mismatch: expected (%0d,%0d), got (%0d,%0d)",
                name, x, y, mask_x, mask_y
            );

        tests_passed++;
        $display("PASS [%0d]: %s", tests_passed, name);
    endtask

    initial begin
        $dumpfile("red_mask.vcd");
        $dumpvars(0, red_mask_tb);

        pixel_rgb565 = '0;
        pixel_x      = '0;
        pixel_y      = '0;
        pixel_valid  = 1'b0;

        // Basic colour classification
        check_pixel("pure red",       16'hF800, 1, 1, 100, 200);
        check_pixel("pure green",     16'h07E0, 1, 0, 110, 200);
        check_pixel("pure blue",      16'h001F, 1, 0, 120, 200);
        check_pixel("pure white",     16'hFFFF, 1, 0, 130, 200);
        check_pixel("pure black",     16'h0000, 1, 0, 140, 200);
        check_pixel("moderate red",   16'hA000, 1, 1, 150, 200);

        // Red intensity threshold: >= 20
        check_pixel("below red min",  16'h9800, 1, 0, 160, 200);
        check_pixel("at red min",     16'hA000, 1, 1, 170, 200);

        // Green and blue contamination
        check_pixel("too much green", 16'hFB20, 1, 0, 180, 200);
        check_pixel("too much blue",  16'hF81F, 1, 0, 190, 200);

        // Pixel stream gating
        check_pixel("invalid red",    16'hF800, 0, 0, 200, 200);
        check_pixel("invalid black",  16'h0000, 0, 0, 210, 200);

        // Coordinate boundaries
        check_pixel("origin",         16'hF800, 1, 1,   0,   0);
        check_pixel("last VGA pixel", 16'hF800, 1, 1, 639, 479);

        $display("----------------------------------------");
        $display("PASS: red_mask_tb (%0d checks)", tests_passed);
        $display("----------------------------------------");

        $finish;
    end

endmodule

`default_nettype wire
