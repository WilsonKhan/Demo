/*
 *  frame_stats.sv -- an EXAMPLE of "the numbers your design computed from a frame": five 32-bit words
 *  per camera frame, for frame_snap.sv to keep with the picture. Replace it with your own design.
 *
 *  It looks only at the pixels the frame buffer keeps (every second pixel of every second row: the
 *  320 x 240 picture that frame_snap keeps), so a golden model can recompute every word from the
 *  grab's frame.hex, and must get the same numbers (tools/check_snap.py does, in the bench):
 *      word 0  frame number: frame boundaries since power-up (says which frame; nothing to recompute)
 *      word 1  "red" pixels: R >= 128, G < 96 and B < 96 on the 8-bit channels (camera_pkg's conversion)
 *      word 2  the sum of the column u (0..319) of the red pixels     centroid = (word 2, word 3) / word 1
 *      word 3  the sum of the row v (0..239) of the red pixels
 *      word 4  the sum of the grey value, camera_pkg's (R + 2G + B) / 4, over all the kept pixels
 *  The sums are kept during the frame and registered at the next frame_start, so the words change
 *  once per frame, at a frame boundary: the pattern frame_snap.sv's "same frame" rule is written for.
 *  Runs on the camera's PCLK, beside the frame buffer's write port, on ov7670_capture's outputs.
 */
module frame_stats #(
    parameter int W = 320,                  // the kept picture: frame_buffer's W and H, decimation 2
    parameter int H = 240
) (
    input  logic          clk,              // PCLK
    input  logic          frame_start,      // ov7670_capture's outputs
    input  logic          valid,
    input  logic [15:0]   pixel,
    input  logic [9:0]    x,
    input  logic [8:0]    y,
    output logic [5*32-1:0] results         // {word 0, word 1, word 2, word 3, word 4}: word 0 in the top bits
);
    import camera_pkg::*;

    logic [31:0]  frame_no = '0, red = '0, sum_u = '0, sum_v = '0, grey_sum = '0;
    logic [159:0] words = '0;
    logic [23:0]  rgb;
    logic         kept, is_red;
    assign kept   = valid && !x[0] && !y[0] && (x[9:1] < 9'(W)) && (y[8:1] < 8'(H));   // what frame_buffer stores
    assign rgb    = rgb565_to_rgb888(pixel);
    assign is_red = (rgb[23:16] >= 8'd128) && (rgb[15:8] < 8'd96) && (rgb[7:0] < 8'd96);

    always_ff @(posedge clk) begin
        if (frame_start) begin                                     // the frame has ended: publish, start again
            words    <= {frame_no, red, sum_u, sum_v, grey_sum};
            frame_no <= frame_no + 1'b1;
            red <= '0; sum_u <= '0; sum_v <= '0; grey_sum <= '0;
        end else if (kept) begin
            grey_sum <= grey_sum + 32'(rgb565_to_grey(pixel));
            if (is_red) begin
                red   <= red + 1'b1;
                sum_u <= sum_u + 32'(x[9:1]);
                sum_v <= sum_v + 32'(y[8:1]);
            end
        end
    end
    assign results = words;
endmodule
