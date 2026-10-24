`timescale 1ns/1ps
`default_nettype none

// MTRX3700 Major Project - V1
// Camera-to-navigation clock-domain crossing.
//
// Source domain: OV7670 PCLK.
// Destination domain: CLOCK_50.
//
// A bundled-data, request/acknowledge toggle handshake transfers
// one completed-frame result atomically.
//
// The source holds its payload stable until acknowledged.
// Only the request/acknowledge toggles cross through synchronisers.
//
// IMPORTANT:
// - Both domains must be reset together before operation.
// - src_frame_done must be a one-cycle source-clock pulse.
// - A result arriving while src_ready=0 is rejected and flagged.
// - The normal camera frame period is much longer than the CDC
//   handshake latency, so overruns should not occur in hardware.
// - Timing constraints must identify the asynchronous clock domains
//   and preserve the intended CDC synchroniser structure.

module vision_result_cdc (
    input  wire       src_clk,
    input  wire       dst_clk,
    input  wire       rst_n,

    // Camera/PCLK domain
    input  wire       src_frame_done,
    input  wire       src_target_valid,
    input  wire [9:0] src_target_x,
    input  wire [9:0] src_target_y,

    output wire       src_ready,
    output logic      src_overrun,

    // Navigation/CLOCK_50 domain
    output logic      dst_frame_done,
    output logic      dst_target_valid,
    output logic [9:0] dst_target_x,
    output logic [9:0] dst_target_y
);

    // ----------------------------------------------------
    // Source-domain payload holding registers
    // ----------------------------------------------------

    logic [20:0] payload_hold;
    logic req_toggle;

    // Acknowledge toggle synchronised back to source domain.
    (* async_reg = "true" *) logic ack_meta;
    (* async_reg = "true" *) logic ack_sync;

    // Request is acknowledged when both toggles match.
    assign src_ready = (req_toggle == ack_sync);

    // ----------------------------------------------------
    // Destination-domain request synchroniser
    // ----------------------------------------------------

    (* async_reg = "true" *) logic req_meta;
    (* async_reg = "true" *) logic req_sync;

    logic ack_toggle;

    // ----------------------------------------------------
    // Source clock domain
    // ----------------------------------------------------

    always_ff @(posedge src_clk or negedge rst_n) begin
        if (!rst_n) begin
            ack_meta     <= 1'b0;
            ack_sync     <= 1'b0;

            req_toggle   <= 1'b0;
            payload_hold <= 21'd0;
            src_overrun  <= 1'b0;

        end else begin
            ack_meta <= ack_toggle;
            ack_sync <= ack_meta;

            if (src_frame_done) begin
                if (src_ready) begin

                    // Capture a coherent snapshot.
                    payload_hold <= {
                        src_target_valid,
                        src_target_x,
                        src_target_y
                    };

                    // Announce a new payload.
                    req_toggle <= ~req_toggle;

                end else begin
                    // Sticky indication that a frame result was
                    // rejected because the prior result was pending.
                    src_overrun <= 1'b1;
                end
            end
        end
    end

    // ----------------------------------------------------
    // Destination clock domain
    // ----------------------------------------------------

    always_ff @(posedge dst_clk or negedge rst_n) begin
        if (!rst_n) begin
            req_meta         <= 1'b0;
            req_sync         <= 1'b0;
            ack_toggle       <= 1'b0;

            dst_frame_done   <= 1'b0;
            dst_target_valid <= 1'b0;
            dst_target_x     <= 10'd0;
            dst_target_y     <= 10'd0;

        end else begin
            req_meta <= req_toggle;
            req_sync <= req_meta;

            dst_frame_done   <= 1'b0;
            dst_target_valid <= 1'b0;

            // A new request has propagated through the
            // synchroniser and has not yet been acknowledged.
            if (req_sync != ack_toggle) begin

                dst_target_valid <= payload_hold[20];
                dst_target_x     <= payload_hold[19:10];
                dst_target_y     <= payload_hold[9:0];

                dst_frame_done   <= 1'b1;

                // Return acknowledgement to source domain.
                ack_toggle <= req_sync;
            end
        end
    end

endmodule

`default_nettype wire
