`timescale 1ns/1ps
`default_nettype none

// MTRX3700 Major Project - V1
// Ultrasonic measurement clock-domain crossing.
//
// Source: Ed sonar_range at 43.904 MHz.
// Destination: CLOCK_50 at 50 MHz.
//
// src_measurement_valid is the Ed sonar_range.valid pulse.
// src_distance is the Ed sonar_range.distance[11:0].
//
// A toggle handshake transfers the 12-bit distance coherently.
// The destination produces a one-cycle measurement_valid pulse.
//
// Reset must initialise both clock domains together.
// Source input must be synchronous to src_clk.

module sonar_result_cdc (
    input  wire        src_clk,
    input  wire        dst_clk,
    input  wire        rst_n,

    input  wire        src_measurement_valid,
    input  wire [11:0] src_distance,

    output wire        src_ready,
    output logic       src_overrun,

    output logic       measurement_valid,
    output logic [15:0] measurement_mm
);

    logic [11:0] distance_hold;
    logic req_toggle;

    (* async_reg = "true" *) logic ack_meta;
    (* async_reg = "true" *) logic ack_sync;

    (* async_reg = "true" *) logic req_meta;
    (* async_reg = "true" *) logic req_sync;

    logic ack_toggle;

    assign src_ready = (req_toggle == ack_sync);

    // 43.904 MHz sonar clock domain.
    always_ff @(posedge src_clk or negedge rst_n) begin
        if (!rst_n) begin
            distance_hold <= 12'd0;
            req_toggle    <= 1'b0;
            ack_meta      <= 1'b0;
            ack_sync      <= 1'b0;
            src_overrun   <= 1'b0;
        end else begin
            ack_meta <= ack_toggle;
            ack_sync <= ack_meta;

            if (src_measurement_valid) begin
                if (src_ready) begin
                    distance_hold <= src_distance;
                    req_toggle    <= ~req_toggle;
                end else begin
                    // Sticky diagnostic for unexpected input rate.
                    src_overrun <= 1'b1;
                end
            end
        end
    end

    // 50 MHz navigation clock domain.
    always_ff @(posedge dst_clk or negedge rst_n) begin
        if (!rst_n) begin
            req_meta          <= 1'b0;
            req_sync          <= 1'b0;
            ack_toggle        <= 1'b0;
            measurement_valid <= 1'b0;
            measurement_mm    <= 16'd0;
        end else begin
            req_meta <= req_toggle;
            req_sync <= req_meta;

            measurement_valid <= 1'b0;

            if (req_sync != ack_toggle) begin
                // Payload has remained stable during request sync.
                measurement_mm <= {4'd0, distance_hold};

                measurement_valid <= 1'b1;
                ack_toggle <= req_sync;
            end
        end
    end

endmodule

`default_nettype wire
