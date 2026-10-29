`timescale 1ns/1ps
/* verilator lint_off PROCASSINIT */
/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off UNUSEDSIGNAL */
// (A testbench: never synthesised.)
/*
 *  top_jtag_tb -- rtl/top_level_jtag.sv, the camera with the JTAG frame grab, pins to pins (README.md).
 *
 *      OV7670 model --GPIO_1[10..25]--> top_level_jtag (PLL, ov7670_config over the SCCB, capture, frame_stats,
 *      frame buffer, frame_snap, display) --Avalon-ST--> vga_sink (VGA Controller + monitor model)
 *                                          frame_snap's memory and probes <-- this bench, as the PC over JTAG
 *
 *  Everything as on the board: the camera model is configured by ov7670_config over the SCCB, window and all;
 *  the scene pans 24 pixels a frame. KEY0 is pressed (the camera is configured), then:
 *    1. KEY1 in the middle of a frame: LEDR4 lights while the snapshot is taken, LEDR3 when it is whole; the
 *       memory then holds every picture position of the next whole frame exactly as the camera sent it, and
 *       frame_stats' words for that frame.
 *    2. the PC's request (the probe's source bit flipped, as tcl/grab_jtag.tcl does): the same, for the frame
 *       after the request; the probes' count and ack move on.
 *  All the while the monitor keeps its picture: no Avalon-ST protocol error at the VGA Controller.
 *  The picture is the one top_level_jtag.sv's SNAP_MODE sets (frame_snap reports it on its probes): 0 = 320 x 240
 *  RGB565 (every second pixel of every second row), 1 = 160 x 120 RGB565 (every fourth), 2 = 320 x 240 grey
 *  (camera_pkg's), two pixels a memory word.
 *  Each snapshot's memory goes to snap_<k>.words with the expected picture and words; tools/check_snap.py then
 *  reads it the three ways a student can and requires exactly that.
 *  Run:  ./simulate.sh top
 */
module top_jtag_tb;
    localparam int W = 320, H = 240, N = 5, PIX0 = 7 + 2 * N;    // the largest picture (SNAP_MODE 0 and 2), 5 words

    logic CLOCK_50 = 1'b0; always #10 CLOCK_50 = ~CLOCK_50;
    logic [3:0] KEY = 4'b1111;
    logic [9:0] SW  = '0;          // SW9 down: the camera's automatic exposure, gain and white balance run
    wire  [9:0] LEDR;
    wire  [35:0] GPIO_1;
    wire  VGA_CLK, VGA_HS, VGA_VS, VGA_BLANK_N, VGA_SYNC_N; wire [7:0] VGA_R, VGA_G, VGA_B;
    top_level_jtag dut (.CLOCK_50, .KEY, .SW, .LEDR, .GPIO_1, .VGA_CLK, .VGA_HS, .VGA_VS, .VGA_BLANK_N, .VGA_SYNC_N,
                        .VGA_R, .VGA_G, .VGA_B);

    // ---- the camera on the ribbon ----
    wire pclk, vsync, href; wire [7:0] d;
    assign GPIO_1[21] = pclk; assign GPIO_1[22] = href; assign GPIO_1[23] = vsync; assign GPIO_1[19:12] = d;
    pullup(GPIO_1[24]);
    int frames_done, write_count, error_count, scene_x0 = 0;
    ov7670_model #(.VERBOSE(0)) cam (
        .sio_c(GPIO_1[25]), .sio_d(GPIO_1[24]), .xclk(GPIO_1[20]), .reset_n(GPIO_1[11]), .pwdn(GPIO_1[10]),
        .pclk(pclk), .vsync(vsync), .href(href), .d(d),
        .scene_mode(1), .scene_x0(scene_x0), .scene_y0(0), .scene_code(8'hA5),
        .frames_done(frames_done), .write_count(write_count), .error_count(error_count));
    always @(posedge vsync) if (dut.cfg_done) scene_x0 <= scene_x0 + 24;

    // ---- the picture SNAP_MODE keeps: set at the start, from frame_snap's probes (bits 1:0) ----
    int mode = -1, pw = W, ph = H, step = 2, row_words = W, depth = PIX0 + W * H + 1;
    string kind = "RGB565";

    // ---- frame by frame: what the camera sent for each picture position, and frame_stats' words ----
    logic [15:0] pic [2][W * H];                                      // grey (SNAP_MODE 2): in the low 8 bits
    logic        pic_ok [2][W * H];
    int          cur = 0, done_bank = 1, cap_frames = 0, at;
    logic [15:0] sent_px;
    logic [5*32-1:0] stats_of [$];
    logic        fs_q = 1'b0;
    always @(posedge pclk) begin
        fs_q <= dut.frame_start;
        if (fs_q) stats_of.push_back(dut.stats);
        if (dut.frame_start) begin
            done_bank = cur; cur = 1 - cur; cap_frames++;
            for (int i = 0; i < W * H; i++) pic_ok[cur][i] = 1'b0;
        end
        if (mode >= 0 && dut.px_valid && int'(dut.px_x) % step == 0 && int'(dut.px_y) % step == 0
                && int'(dut.px_x) / step < pw && int'(dut.px_y) / step < ph) begin
            at = (int'(dut.px_y) / step) * pw + int'(dut.px_x) / step;
            sent_px = cam.expected_word(int'(dut.px_x), int'(dut.px_y));
            pic[cur][at] = (mode == 2) ? 16'(camera_pkg::rgb565_to_grey(sent_px)) : sent_px;
            pic_ok[cur][at] = 1'b1;
        end
    end

    // the frame a snapshot captures: frame_snap goes from S_CAPTURE to S_RESULTS at the frame_start that ends it;
    // at that clock done_bank (swapped on the same edge) holds what the camera sent in it
    int captured = -1, wrong = 0, not_sent = 0, a0;
    always @(posedge pclk) if (dut.snap_u.state == 3'd2 && dut.frame_start) begin
        #1;                                                            // after the bank swap on this edge
        captured = cap_frames - 1;
        wrong = 0; not_sent = 0;
        for (int w = 0; w < row_words * ph; w++)
            if (mode == 2) begin                                       // two grey pixels a word, the left one high
                a0 = (w / row_words) * pw + 2 * (w % row_words);
                if (!pic_ok[done_bank][a0] || !pic_ok[done_bank][a0 + 1]) not_sent++;
                else if (dut.snap_u.ram_u.mem[PIX0 + w] !== {pic[done_bank][a0][7:0], pic[done_bank][a0 + 1][7:0]}) wrong++;
            end else begin
                if (!pic_ok[done_bank][w]) not_sent++;
                else if (dut.snap_u.ram_u.mem[PIX0 + w] !== pic[done_bank][w]) wrong++;
            end
    end

    int fails = 0, vga_errors_before, busy_seen = 0;
    string out = ".";
    task automatic fail(input string s);
        fails++;
        $display("FAIL: %s", s);
    endtask
    always @(posedge CLOCK_50) if (LEDR[4]) busy_seen++;

    task automatic check_snapshot(input int k, input string how);
        int fd;
        if (captured < 0) begin fail($sformatf("snapshot %0d (%s): never captured", k, how)); return; end
        if (wrong != 0) fail($sformatf("snapshot %0d (%s): %0d picture words differ from what the camera sent", k, how, wrong));
        if (not_sent != 0) fail($sformatf("snapshot %0d (%s): %0d picture words not sent in the frame", k, how, not_sent));
        for (int i = 0; i < N; i++)
            if ({dut.snap_u.ram_u.mem[7 + 2 * i], dut.snap_u.ram_u.mem[8 + 2 * i]} !== stats_of[captured][32 * (N - 1 - i) +: 32])
                fail($sformatf("snapshot %0d (%s): word %0d is not frame_stats' for the captured frame", k, how, i));
        fd = $fopen($sformatf("%s/snap_%0d.words", out, k), "w");
        for (int a = 0; a < depth; a++) $fdisplay(fd, "%04x", dut.snap_u.ram_u.mem[a]);
        $fclose(fd);
        fd = $fopen($sformatf("%s/expected_%0d.hex", out, k), "w");
        for (int i = 0; i < pw * ph; i++)
            if (mode == 2) $fdisplay(fd, "%02x", pic[done_bank][i][7:0]);
            else           $fdisplay(fd, "%04x", pic[done_bank][i]);
        $fclose(fd);
        fd = $fopen($sformatf("%s/expected_results_%0d.txt", out, k), "w");
        for (int i = 0; i < N; i++) $fdisplay(fd, "%08x", stats_of[captured][32 * (N - 1 - i) +: 32]);
        $fclose(fd);
        $display("top_jtag: snapshot %0d (%s): frame %0d kept, %0d of %0d picture words as the camera sent them, frame_stats' words",
                 k, how, captured, row_words * ph - wrong - not_sent, row_words * ph);
    endtask

    initial begin
        int c0, f0;
        if ($value$plusargs("out=%s", out)) ;
        fork begin #3s; $display("FAILED: top_jtag_tb: timed out"); $finish; end join_none
        #200ns;
        mode = int'(dut.snap_u.probes_u.probe[1:0]);                  // top_level_jtag.sv's SNAP_MODE
        pw = (mode == 1) ? 160 : 320; ph = (mode == 1) ? 120 : 240; step = (mode == 1) ? 4 : 2;
        row_words = (mode == 2) ? pw / 2 : pw; depth = PIX0 + row_words * ph + 1;
        if (mode == 2) kind = "grey";
        $display("[tb] top_level_jtag's SNAP_MODE is %0d: the snapshot keeps %0d x %0d %s", mode, pw, ph, kind);
        if (mode > 2) fail($sformatf("SNAP_MODE %0d: frame_snap takes 0, 1 or 2", mode));
        KEY[0] = 1'b0; #500ns KEY[0] = 1'b1;                          // KEY0: configure the camera
        wait (dut.cfg_done);
        $display("[tb @%0t] camera configured over the SCCB (%0d writes, %0d SCCB errors)", $time, write_count, error_count);
        @(posedge dut.frame_start); @(posedge dut.frame_start);
        if (LEDR[3] || LEDR[4]) fail("before any snapshot: LEDR3 or LEDR4 lit");
        vga_errors_before = dut.vga_u.errors;

        // 1. KEY1
        wait (dut.px_valid && dut.px_y == 240);
        f0 = cap_frames; captured = -1; busy_seen = 0;
        KEY[1] = 1'b0; #1ms KEY[1] = 1'b1;
        wait (LEDR[3]);
        #1us;
        if (captured != f0 + 1) fail($sformatf("snapshot 1 (KEY1): kept frame %0d, expected %0d (the next whole frame)", captured, f0 + 1));
        if (busy_seen == 0) fail("snapshot 1 (KEY1): LEDR4 never lit");
        check_snapshot(1, "KEY1");

        // 2. the PC's request, through the probes
        repeat (2) @(posedge dut.frame_start);
        wait (dut.px_valid && dut.px_y == 100);
        f0 = cap_frames; captured = -1;
        c0 = int'(dut.snap_u.probes_u.probe[20:5]);
        dut.snap_u.probes_u.src_jtag = ~dut.snap_u.probes_u.src_jtag;
        wait (int'(dut.snap_u.probes_u.probe[20:5]) == c0 + 1 && LEDR[3]);
        #1us;
        if (captured != f0 + 1) fail($sformatf("snapshot 2 (the PC): kept frame %0d, expected %0d", captured, f0 + 1));
        if (dut.snap_u.probes_u.probe[4] !== dut.snap_u.probes_u.src_jtag[0]) fail("snapshot 2 (the PC): the probes' ack is not the request bit");
        check_snapshot(2, "the PC");

        if (dut.vga_u.errors != vga_errors_before) fail($sformatf("%0d Avalon-ST protocol errors at the VGA Controller", dut.vga_u.errors - vga_errors_before));
        if (fails == 0)
            $display("PASS: top_jtag_tb: rtl/top_level_jtag.sv, pins to pins: KEY1 and the PC's request each kept the next whole frame as the camera sent it, with frame_stats' words; LEDR4 while taking it, LEDR3 when whole; the monitor undisturbed");
        else $display("FAILED: top_jtag_tb: %0d problems", fails);
        $finish;
    end
endmodule
