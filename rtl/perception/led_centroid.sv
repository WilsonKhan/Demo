`timescale 1ns/1ps
`default_nettype none

// Group 26 V1 timing-closure revision.
// Accumulate qualifying pixels at PCLK rate; calculate frame centroid
// by 32 sequential unsigned division steps after frame_end.
// frame_done and target_valid are aligned single-cycle output pulses.
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
    logic [31:0] sum_x, sum_y, count;
    wire [31:0] base_x = frame_start ? 32'd0 : sum_x;
    wire [31:0] base_y = frame_start ? 32'd0 : sum_y;
    wire [31:0] base_count = frame_start ? 32'd0 : count;
    wire use_pixel = pixel_valid && is_red;
    wire [31:0] next_x = base_x + (use_pixel ? {22'd0, pixel_x} : 32'd0);
    wire [31:0] next_y = base_y + (use_pixel ? {22'd0, pixel_y} : 32'd0);
    wire [31:0] next_count = base_count + (use_pixel ? 32'd1 : 32'd0);

    logic busy;
    logic result_is_valid;
    logic [5:0] bits_left;
    logic [31:0] denominator, dividend_x, dividend_y;
    logic [31:0] quotient_x, quotient_y;
    logic [32:0] remainder_x, remainder_y;

    wire [32:0] trial_x = {remainder_x[31:0], dividend_x[31]};
    wire [32:0] trial_y = {remainder_y[31:0], dividend_y[31]};
    wire [32:0] divisor = {1'b0, denominator};
    wire quotient_bit_x = trial_x >= divisor;
    wire quotient_bit_y = trial_y >= divisor;
    wire [31:0] updated_quotient_x = {quotient_x[30:0], quotient_bit_x};
    wire [31:0] updated_quotient_y = {quotient_y[30:0], quotient_bit_y};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_x <= 0; sum_y <= 0; count <= 0;
            busy <= 0; result_is_valid <= 0; bits_left <= 0;
            denominator <= 0; dividend_x <= 0; dividend_y <= 0;
            quotient_x <= 0; quotient_y <= 0;
            remainder_x <= 0; remainder_y <= 0;
            target_x <= 0; target_y <= 0; red_count <= 0;
            frame_done <= 0; target_valid <= 0;
        end else begin
            frame_done <= 1'b0;
            target_valid <= 1'b0;

            // Accumulation stays independent of the calculation engine.
            // The frame_end pixel is included in next_x/y/count.
            if (frame_end) begin
                sum_x <= 0;
                sum_y <= 0;
                count <= 0;
            end else begin
                sum_x <= next_x;
                sum_y <= next_y;
                count <= next_count;
            end

            if (busy) begin
                dividend_x <= {dividend_x[30:0], 1'b0};
                dividend_y <= {dividend_y[30:0], 1'b0};
                remainder_x <= quotient_bit_x ? (trial_x - divisor) : trial_x;
                remainder_y <= quotient_bit_y ? (trial_y - divisor) : trial_y;
                quotient_x <= updated_quotient_x;
                quotient_y <= updated_quotient_y;
                bits_left <= bits_left - 6'd1;
                if (bits_left == 6'd1) begin
                    busy <= 1'b0;
                    frame_done <= 1'b1;
                    target_valid <= result_is_valid;
                    target_x <= result_is_valid ? updated_quotient_x[9:0] : 10'd0;
                    target_y <= result_is_valid ? updated_quotient_y[9:0] : 10'd0;
                end
            end else if (frame_end) begin
                // Normal 640x480 frames are vastly longer than 32 PCLK cycles.
                // A second frame_end while busy is not supported by this V1 block.
                red_count <= next_count;
                denominator <= (next_count == 0) ? 32'd1 : next_count;
                dividend_x <= next_x;
                dividend_y <= next_y;
                quotient_x <= 0;
                quotient_y <= 0;
                remainder_x <= 0;
                remainder_y <= 0;
                bits_left <= 6'd32;
                result_is_valid <= (next_count >= MIN_PIXELS) && (next_count != 0);
                busy <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
