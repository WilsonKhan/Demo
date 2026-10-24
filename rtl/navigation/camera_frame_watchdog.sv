`timescale 1ns/1ps
`default_nettype none

// Group 26 - V1 camera freshness watchdog.
//
// Clock: CLOCK_50.
//
// A completed camera frame resets the age counter.
// Motion is permitted only while a valid target has
// been seen within the timeout window.
//
// No target in a completed frame immediately clears
// the usable-target flag.
//
// Missing frames eventually clear the target flag.
//
// The default timeout is 150 ms at 50 MHz.
// Parameters may be reduced for simulation.

module camera_frame_watchdog #(
    parameter int unsigned MAX_AGE_CYCLES = 7_500_000
) (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       frame_done,
    input  wire       target_valid,
    input  wire [9:0] target_x,

    output logic      target_fresh,
    output logic [9:0] fresh_target_x
);

    localparam int AGE_WIDTH =
        (MAX_AGE_CYCLES > 1)
        ? $clog2(MAX_AGE_CYCLES + 1)
        : 1;

    logic [AGE_WIDTH-1:0] age;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            age            <= '0;
            target_fresh   <= 1'b0;
            fresh_target_x <= 10'd0;
        end else if (frame_done) begin
            age <= '0;

            if (target_valid) begin
                target_fresh   <= 1'b1;
                fresh_target_x <= target_x;
            end else begin
                target_fresh   <= 1'b0;
                fresh_target_x <= 10'd0;
            end

        end else if (age >= AGE_WIDTH'(MAX_AGE_CYCLES - 1)) begin
            age            <= age;
            target_fresh   <= 1'b0;
            fresh_target_x <= 10'd0;
        end else begin
            age <= age + 1'b1;
        end
    end

endmodule

`default_nettype wire
