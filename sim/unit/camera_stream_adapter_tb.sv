`timescale 1ns/1ps
`default_nettype none

module camera_stream_adapter_tb;

    logic        cam_frame_start = 1'b0;
    logic        cam_valid = 1'b0;
    logic [15:0] cam_pixel = 16'd0;
    logic [9:0]  cam_x = 10'd0;
    logic [8:0]  cam_y = 9'd0;

    wire        frame_start;
    wire        frame_end;
    wire        pixel_valid;
    wire [15:0] pixel_rgb565;
    wire [9:0]  pixel_x;
    wire [9:0]  pixel_y;

    int checks = 0;

    camera_stream_adapter dut (
        .cam_frame_start(cam_frame_start),
        .cam_valid(cam_valid),
        .cam_pixel(cam_pixel),
        .cam_x(cam_x),
        .cam_y(cam_y),

        .frame_start(frame_start),
        .frame_end(frame_end),
        .pixel_valid(pixel_valid),
        .pixel_rgb565(pixel_rgb565),
        .pixel_x(pixel_x),
        .pixel_y(pixel_y)
    );

    task automatic check_stream(
        input string name,
        input bit start_in,
        input bit valid_in,
        input logic [15:0] rgb,
        input logic [9:0] x,
        input logic [8:0] y,
        input bit expected_end
    );

        cam_frame_start = start_in;
        cam_valid       = valid_in;
        cam_pixel       = rgb;
        cam_x           = x;
        cam_y           = y;

        #10;

        if (frame_start !== start_in)
            $fatal(1, "FAIL %s: frame_start", name);

        if (pixel_valid !== valid_in)
            $fatal(1, "FAIL %s: pixel_valid", name);

        if (pixel_rgb565 !== rgb)
            $fatal(1, "FAIL %s: RGB565 mismatch", name);

        if (pixel_x !== x || pixel_y !== {1'b0, y})
            $fatal(1,
                "FAIL %s: coordinates expected (%0d,%0d), got (%0d,%0d)",
                name, x, y, pixel_x, pixel_y
            );

        if (frame_end !== expected_end)
            $fatal(1,
                "FAIL %s: frame_end expected=%b actual=%b",
                name, expected_end, frame_end
            );

        checks++;

        $display("PASS [%0d]: %s", checks, name);

    endtask

    initial begin

        $dumpfile("camera_stream_adapter.vcd");
        $dumpvars(0, camera_stream_adapter_tb);

        check_stream(
            "idle",
            0, 0, 16'h0000, 0, 0, 0
        );

        check_stream(
            "frame start without pixel",
            1, 0, 16'h0000, 0, 0, 0
        );

        check_stream(
            "first valid pixel",
            0, 1, 16'hF800, 0, 0, 0
        );

        check_stream(
            "middle-frame red pixel",
            0, 1, 16'hF800, 320, 240, 0
        );

        check_stream(
            "RGB565 white pixel",
            0, 1, 16'hFFFF, 400, 200, 0
        );

        check_stream(
            "last column before last row",
            0, 1, 16'h07E0, 639, 478, 0
        );

        check_stream(
            "penultimate pixel",
            0, 1, 16'h001F, 638, 479, 0
        );

        check_stream(
            "last pixel completes frame",
            0, 1, 16'hF800, 639, 479, 1
        );

        check_stream(
            "invalid last coordinates do not complete",
            0, 0, 16'hF800, 639, 479, 0
        );

        check_stream(
            "next frame start",
            1, 0, 16'h0000, 0, 0, 0
        );

        check_stream(
            "next frame first valid pixel",
            0, 1, 16'hF800, 0, 0, 0
        );

        $display("-----------------------------------------------");
        $display("PASS: camera_stream_adapter_tb (%0d checks)",
                 checks);
        $display("-----------------------------------------------");

        $finish;

    end

endmodule

`default_nettype wire
