`timescale 1ns/1ps
/* verilator lint_off PROCASSINIT */
/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off UNUSEDSIGNAL */
// (A testbench: never synthesised.)
/*
 *  replay_tb -- a replay (README.md). Run it in a folder grab.py has written (scene.hex, frame.hex).
 *
 *      scene.hex --> OV7670 model (SCENE_FILE) --> ov7670_capture --+--> frame_buffer
 *                                                    |              +--> YOUR MODULE (frame_stats.sv)
 *                          every pixel of one frame vs frame.hex     every word vs frame.hex, once that frame is in;
 *                          pixel-doubled                             the module's words vs the board's
 *
 *  The stored frame and the sensor: the camera sends 640 x 480 pixels; frame_buffer keeps camera pixel
 *  (2u, 2v) as stored pixel (u, v), u < 320, v < 240, and drops the rest. grab.py's scene puts stored pixel
 *  (u, v) on the four sensor pixels that come out as camera pixels (2u..2u+1, 2v..2v+1), so the camera model
 *  sends the frame pixel-doubled. The comparison is exact: camera pixel (x, y) must equal frame.hex's
 *  word (x/2, y/2), all 307,200 of them, and the buffer must then hold frame.hex, all 76,800 words. Readout
 *  rows above row 11 are not picture on the chip (row 10 is a dark blue line, whatever the scene), and the model
 *  does the same (measured on a board), so a window that starts above row 11 has rows that are checked against
 *  the model's own words (cam.expected_word) instead; the camera code's window starts at row 11 and has none.
 *
 *  The picture must be SNAP_MODE 0's: 320 x 240 RGB565, the frame buffer's own. +width=<n> and +height=<n> say
 *  what grab.py found (simulate.sh takes them from results.json), and any other size stops the bench: a 160 x 120
 *  grab (SNAP_MODE 1) keeps only every fourth pixel, and a grey one (SNAP_MODE 2) no colour, so neither can be
 *  sent again exactly.
 *
 *  YOUR MODULE: the module whose numbers the board kept with the picture (frame_stats.sv, top_level_jtag.sv's
 *  example, or your own in its place) runs here too, on the same capture outputs, so it sees the frame the board
 *  saw. With +results=<file> (the board's result words from results.json, 8 hex digits a line, word 0 first;
 *  simulate.sh writes it) and +n_results=<n>, its words for the replayed frame, taken at the next frame's first
 *  pixel as frame_snap takes them, must be the board's from word 1 on. Word 0 is not compared: frame_stats'
 *  word 0 is the frame number, which differs. Put your own module at YOUR MODULE below, with the same ports, and
 *  set N_RESULTS and YOURS to match.
 *
 *  The camera model gets the camera code's registers (RGB565 VGA, 20 MHz PCLK, mirror + flip, rows from 11,
 *  the window from column 160, and the tuning and colour blocks with cam.set_course_tuning()). +hstart=<n> and
 *  +vstart=<n> move the window's first column and row; grab.py must have been run with the same --hstart and
 *  --vstart. The model places the camera code's window on the central 640 columns of its
 *  656-column array and sends all 640; a window from column 152 to 168 lands on the array too. For any
 *  other, grab.py prints a NOTE, and this bench fails on the columns the model cannot show.
 *  Run:  ./simulate.sh replay <folder>     (a folder grab.py has written; without one, the top bench's grab)
 */
module replay_tb;
    localparam int W = 320, H = 240;
    logic xclk = 1'b0; always #50 xclk = ~xclk;                     // 10 MHz XCLK, / 2 x 4 = 20 MHz PCLK
    logic reset_n = 1'b0;
    wire  sio_d; logic sio_c = 1'b1; pullup(sio_d);
    wire  pclk, vsync, href; wire [7:0] d;
    int   frames_done, write_count, error_count;
    ov7670_model #(.VERBOSE(0), .SCENE_FILE("scene.hex")) cam (
        .sio_c(sio_c), .sio_d(sio_d), .xclk(xclk), .reset_n(reset_n), .pwdn(1'b0),
        .pclk(pclk), .vsync(vsync), .href(href), .d(d),
        .scene_mode(1), .scene_x0(0), .scene_y0(0), .scene_code(8'hA5),
        .frames_done(frames_done), .write_count(write_count), .error_count(error_count));

    wire        frame_start, px_valid;
    wire [15:0] px, rd_pixel;
    wire [9:0]  px_x;
    wire [8:0]  px_y;
    ov7670_capture #(.INPUT_STAGE(1)) cap (.pclk(pclk), .vsync(vsync), .href(href), .d(d),
        .frame_start(frame_start), .valid(px_valid), .pixel(px), .x(px_x), .y(px_y));
    frame_buffer #(.W(W), .H(H), .DW(16), .DECIMATE(2), .BUFFERS(1), .PACKED(0)) fb (
        .wr_clk(pclk), .wr_frame_start(frame_start), .wr_valid(px_valid), .wr_x(px_x), .wr_y(px_y), .wr_pixel(px),
        .rd_clk(pclk), .rd_x(9'd0), .rd_y(8'd0), .rd_pixel(rd_pixel));

    // ---- YOUR MODULE: the module whose numbers the board kept ------------------------------------------------
    // frame_stats is top_level_jtag.sv's example. Put your own here instead, on the same capture outputs, with its
    // words in `results` (word 0 in the top 32 bits), and set N_RESULTS (its number of words) and YOURS (its name).
    localparam int    N_RESULTS = 5;
    localparam string YOURS     = "frame_stats";
    wire [32*N_RESULTS-1:0] results;
    frame_stats #(.W(W), .H(H)) yours_u (.clk(pclk), .frame_start(frame_start), .valid(px_valid), .pixel(px),
        .x(px_x), .y(px_y), .results(results));

    logic [15:0] frame [W * H];                                       // what the dump said
    initial $readmemh("frame.hex", frame);
    int hstart = 160, vstart = 11;                                    // the window's first column and row: the camera code's
    function automatic bit not_picture(input int camera_row);         // a readout row above 11: the chip's, not the scene's
        return camera_row + vstart < 11;
    endfunction
    logic checking = 1'b0;
    int pixels = 0, bad = 0, bad_stored = 0, max_x = -1;
    logic [15:0] want;
    always @(posedge pclk) if (checking && px_valid) begin
        pixels++;
        if (int'(px_x) > max_x) max_x = px_x;
        want = not_picture(int'(px_y)) ? cam.expected_word(int'(px_x), int'(px_y)) : frame[int'(px_y[8:1]) * W + int'(px_x[9:1])];
        if (px !== want) begin
            bad++;
            if (!px_x[0] && !px_y[0]) bad_stored++;
            if (bad <= 5) $display("FAIL: camera pixel (%0d,%0d) = %04h, frame.hex (%0d,%0d) = %04h", px_x, px_y, px, px_x[9:1], px_y[8:1], want);
        end
    end

    // the board's result words (+results), and the module's for the replayed frame
    logic [31:0] board [16];
    string       board_file, mine_text, board_text;
    int          n_board = 0, words_bad = 0;
    logic [31:0] w_mine;

    int fails = 0, stop, vstop, buf_bad = 0, rows_np = 0, pic_w = W, pic_h = H;
    initial begin
        if ($value$plusargs("hstart=%d", hstart)) ;
        if ($value$plusargs("vstart=%d", vstart)) ;
        if ($value$plusargs("width=%d", pic_w)) ;
        if ($value$plusargs("height=%d", pic_h)) ;
        if (pic_w != W || pic_h != H) begin
            $display("FAILED: replay_tb: the grab is %0d x %0d, and a replay takes SNAP_MODE 0's %0d x %0d RGB565 picture (the frame buffer's own)",
                     pic_w, pic_h, W, H);
            $finish;
        end
        if ($value$plusargs("results=%s", board_file)) begin
            if (!$value$plusargs("n_results=%d", n_board) || n_board < 1 || n_board > 16) begin
                $display("FAILED: replay_tb: +results=%s needs +n_results=<1 to 16>", board_file);
                $finish;
            end
            $readmemh(board_file, board, 0, n_board - 1);
        end
        stop = (hstart + 640) % 784;                                  // the window: 640 columns from hstart
        vstop = (vstart + 480) % 510;                                 // and 480 rows from vstart
        for (int y = 0; y < 480; y++) if (not_picture(y)) rows_np++;
        fork begin #200ms; $display("FAILED: replay_tb: timed out"); $finish; end join_none
        #10us reset_n = 1'b1;
        #1.5ms;
        cam.set_reg(8'h3A, 8'h04); cam.set_reg(8'h11, 8'h81); cam.set_reg(8'h6B, 8'h4A);     // TSLB, CLKRC, DBLV: /2 and x4, 20 MHz (25 fps)
        cam.set_reg(8'h12, 8'h04); cam.set_reg(8'h40, 8'hD0);                                 // RGB565 VGA, full range
        cam.set_reg(8'h17, 8'(hstart >> 3)); cam.set_reg(8'h18, 8'(stop >> 3));               // HSTART, HSTOP
        cam.set_reg(8'h32, 8'(8'h80 | ((stop & 7) << 3) | (hstart & 7)));                     // HREF
        cam.set_reg(8'h19, 8'(vstart >> 2)); cam.set_reg(8'h1A, 8'(vstop >> 2));             // VSTRT, VSTOP
        cam.set_reg(8'h03, 8'(((vstop & 3) << 2) | (vstart & 3)));                            // VREF (the camera code's: 0x0F)
        cam.set_reg(8'h1E, 8'h37);                                                            // mirror + flip
        cam.set_course_tuning();                                                              // the course's colours
        @(posedge frame_start);                                       // the frame the registers changed in is over
        checking = 1'b1;
        @(posedge frame_start);                                       // one whole frame checked
        checking = 1'b0;
        for (int i = 0; i < W * H; i++)
            if (fb.mem[i] !== (not_picture(2 * (i / W)) ? cam.expected_word(2 * (i % W), 2 * (i / W)) : frame[i])) buf_bad++;
        $display("replay: window from column %0d; one frame: %0d camera pixels, columns 0..%0d; %0d differ from frame.hex pixel-doubled (%0d of them stored ones); the buffer: %0d of %0d words differ",
                 hstart, pixels, max_x, bad, bad_stored, buf_bad, W * H);
        if (pixels != 640 * 480 || max_x != 639) begin
            fails++; $display("FAIL: %0d pixels in the frame up to column %0d, expected %0d up to 639", pixels, max_x, 640 * 480);
        end
        if (bad != 0 || buf_bad != 0) fails++;

        // YOUR MODULE's words for that frame, at the next frame's first pixel (where frame_snap takes them)
        if (n_board > 0) begin
            do @(posedge pclk); while (!px_valid);
            mine_text = ""; board_text = "";
            for (int i = 1; i < N_RESULTS || i < n_board; i++) begin
                w_mine = (i < N_RESULTS) ? results[32 * (N_RESULTS - 1 - i) +: 32] : 'x;
                if (i < N_RESULTS) mine_text = {mine_text, $sformatf(" %0d", w_mine)};
                if (i < n_board) board_text = {board_text, $sformatf(" %0d", board[i])};
                if (i >= N_RESULTS || i >= n_board || w_mine !== board[i]) words_bad++;
            end
            $display("replay: %s on the replayed frame, words 1 on:%s; the board's (results.json):%s", YOURS, mine_text, board_text);
            if (n_board != N_RESULTS) begin
                fails++; $display("FAIL: the board kept %0d result words, and %s gives %0d (N_RESULTS at YOUR MODULE)", n_board, YOURS, N_RESULTS);
            end else if (words_bad != 0) begin
                fails++; $display("FAIL: %s: %0d of words 1 to %0d differ from the board's", YOURS, words_bad, N_RESULTS - 1);
            end
        end else
            $display("replay: no +results: %s is not compared with the board's words", YOURS);

        if (fails == 0)
            $display("PASS: replay_tb (window from column %0d, row %0d): scene.hex through the camera model and the capture code: all %0d pixels of a frame are frame.hex pixel-doubled%s, and the frame buffer holds the same, all %0d words%s",
                     hstart, vstart, 640 * 480, (rows_np > 0) ? $sformatf(" (but the first %0d row(s): readout rows above 11, the chip's own colours)", rows_np) : "", W * H,
                     (n_board > 0) ? $sformatf("; %s gives the board's words 1 to %0d", YOURS, N_RESULTS - 1) : "");
        else $display("FAILED: replay_tb (window from column %0d, row %0d): %0d problems", hstart, vstart, fails);
        $finish;
    end
endmodule
