`timescale 1ns/1ps
`default_nettype none

// MTRX3700 Major Project - V1
// Sonar measurement freshness and validity monitor.
//
// measurement_valid: one-clock pulse indicating a NEW reading.
// measurement_mm: measured distance in millimetres.
//
// sonar_valid stays high only while a recent, in-range
// measurement is available.
//
// A new invalid measurement immediately invalidates the
// previous reading.
//
// If no new measurement arrives for MAX_AGE_CYCLES,
// sonar_valid clears automatically.
//
// IMPORTANT:
// This module assumes all inputs are synchronous to clk.
// It does not generate ultrasonic trigger pulses.

module sonar_freshness #(
    parameter int unsigned MAX_AGE_CYCLES = 32'd12500000,
    parameter logic [15:0] MIN_RANGE_MM = 16'd20,
    parameter logic [15:0] MAX_RANGE_MM = 16'd3500
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        measurement_valid,
    input  wire [15:0] measurement_mm,

    output logic       sonar_valid,
    output logic [15:0] distance_mm
);

    logic [31:0] age_cycles;

    wire measurement_in_range =
        (measurement_mm >= MIN_RANGE_MM) &&
        (measurement_mm <= MAX_RANGE_MM);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sonar_valid <= 1'b0;
            distance_mm <= 16'd0;
            age_cycles  <= 32'd0;

        end else if (measurement_valid) begin

            age_cycles <= 32'd0;

            if (measurement_in_range) begin
                sonar_valid <= 1'b1;
                distance_mm <= measurement_mm;
            end else begin
                sonar_valid <= 1'b0;
                distance_mm <= 16'd0;
            end

        end else if (sonar_valid) begin

            if (age_cycles >= (MAX_AGE_CYCLES - 1)) begin
                sonar_valid <= 1'b0;
                distance_mm <= 16'd0;
                age_cycles  <= 32'd0;
            end else begin
                age_cycles <= age_cycles + 32'd1;
            end

        end else begin
            age_cycles <= 32'd0;
        end
    end

endmodule

`default_nettype wire

