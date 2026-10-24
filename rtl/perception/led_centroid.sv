`timescale 1ns/1ps
`default_nettype none

// MTRX3700 Major Project - V1
// Streaming centroid of red camera pixels.
//
// frame_start: first pixel/cycle of a new frame
// frame_end:   final pixel/cycle of the frame
//
// frame_done pulses for one clock on every completed frame.
// target_valid pulses only when that completed frame contains
// at least MIN_PIXELS qualifying pixels.
//
// Both outputs are registered and aligned.
//
// Coordinates are unsigned integer averages, rounded down.
//
// IMPORTANT:
// The camera pixel stream and frame boundary signals must be
// synchronous to clk before entering this module.

module led_centroid #(
    parameter logic [31:0] MIN_PIXELS = 32'd20
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        frame_start,
    input  wire        frame_end,

    input  wire        pixel_valid,
    input  wire        is_red,
    input  wire [9:0]  pixel_x,
    input  wire [9:0]  pixel_y,

    output logic        frame_done,
    output logic        target_valid,
    output logic [9:0]  target_x,
    output logic [9:0]  target_y,
    output logic [31:0] red_count
);

    logic [31:0] sum_x;
    logic [31:0] sum_y;
    logic [31:0] count;

    logic [31:0] base_x;
    logic [31:0] base_y;
    logic [31:0] base_count;

    logic [31:0] next_x;
    logic [31:0] next_y;
    logic [31:0] next_count;

    // Account for the current pixel when calculating a result
    // on the same clock as frame_end.
    //
    // frame_start first clears the old accumulation, but the
    // first pixel of the new frame can still be counted.

    always_comb begin
        base_x     = frame_start ? 32'd0 : sum_x;
        base_y     = frame_start ? 32'd0 : sum_y;
        base_count = frame_start ? 32'd0 : count;

        next_x     = base_x;
        next_y     = base_y;
        next_count = base_count;

        if (pixel_valid && is_red) begin
            next_x     = base_x + {22'd0, pixel_x};
            next_y     = base_y + {22'd0, pixel_y};
            next_count = base_count + 32'd1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_x        <= 32'd0;
            sum_y        <= 32'd0;
            count        <= 32'd0;

            frame_done   <= 1'b0;
            target_valid <= 1'b0;

            target_x     <= 10'd0;
            target_y     <= 10'd0;
            red_count    <= 32'd0;

        end else begin

            // Both status signals are one-clock pulses.
            frame_done   <= frame_end;
            target_valid <= 1'b0;

            if (frame_end) begin

                // Report the number of qualifying pixels
                // in the frame that has just completed.
                red_count <= next_count;

                if ((next_count >= MIN_PIXELS) &&
                    (next_count != 32'd0)) begin

                    target_x     <= 10'(next_x / next_count);
                    target_y     <= 10'(next_y / next_count);
                    target_valid <= 1'b1;

                end else begin

                    // Do not preserve a stale target when
                    // the LED disappears or is too small.
                    target_x <= 10'd0;
                    target_y <= 10'd0;

                end

                // Reset accumulation for the next frame.
                sum_x <= 32'd0;
                sum_y <= 32'd0;
                count <= 32'd0;

            end else begin

                // Continue accumulating the current frame.
                sum_x <= next_x;
                sum_y <= next_y;
                count <= next_count;

            end
        end
    end

endmodule

`default_nettype wire
