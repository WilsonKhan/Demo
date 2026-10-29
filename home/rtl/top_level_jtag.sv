/*
 *  top_level_jtag.sv -- the OV7670 camera on the DE1-SoC, live on the VGA monitor, with the JTAG frame grab:
 *  a snapshot memory the PC reads over the USB-Blaster (frame_snap.sv). The default way to grab a frame on the bench.
 *
 *      CLOCK_50 --> video_pll --> clk_25 (display, SCCB /250) and clk_10 --> camera XCLK (GPIO_1[20]), /2 and x4 inside the camera = 20 MHz PCLK (CAMERA_FPS 25)
 *                                   |
 *      clock_divider --> 100 kHz --> ov7670_config --SCCB--> camera (RESET#, PWDN, SIO_C, SIO_D)
 *                                    ov7670_hold   --SCCB--> (the same bus, once ov7670_config is done)
 *
 *      camera PCLK/VSYNC/HREF/D --> ov7670_capture --+--> frame_buffer --> camera_display --Avalon-ST--> vga_sink.qsys --> VGA
 *                                                    +--> frame_stats (your design's numbers) --+
 *                                                    +--> frame_snap <------------------------+ --JTAG--> the PC
 *
 *  Pins: the Robot Adaptor Board puts the camera on GPIO_1[10..25]; the stock DE1-SoC pin assignments are used:
 *      PWDN 10, RESET# 11, D0..D7 12..19, XCLK 20, PCLK 21, HREF 22, VSYNC 23, SIO_D 24, SIO_C 25.
 *
 *  Controls: KEY0 = reset (re-runs the camera configuration). LEDR0 = camera configured, LEDR1 = the last SCCB
 *  write got no acknowledge (being retried: check the loom and XCLK), LEDR2 toggles once per camera frame.
 *  SW9 up holds the camera's automatic exposure, gain and white balance (ov7670_hold.sv), so that the colours you
 *  grab stay put while you change the scene; SW9 down lets the camera adjust them again. LEDR9 = held, LEDR8 = the
 *  hold's last write was not acknowledged (being sent again).
 *
 *  FRAME GRAB: KEY1 (or tcl/grab_jtag.tcl) keeps the next whole frame and frame_stats' five numbers for it in the
 *  memory GRAB; LEDR3 is lit while a whole snapshot is held, LEDR4 while one is being taken. Read it with
 *  `quartus_stp -t tcl/grab_jtag.tcl`, or by hand in Tools > In-System Memory Content Editor (README.md).
 *  SNAP_MODE 1 or 2 keeps a smaller picture, for a design that needs the memory (frame_snap.sv).
 */
module top_level_jtag #(
    parameter int  CAMERA_FPS = 25,             // the camera's frame rate: 25 (the default) or 50, an overclock (the camera lesson's slide 2.5)
    parameter int SNAP_MODE = 0                // frame_snap's MODE: 0 = 320 x 240 RGB565, 1 = 160 x 120 RGB565, 2 = 320 x 240 grey
) (
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,
    input  wire [9:0]  SW,
    output wire [9:0]  LEDR,
    inout  wire [35:0] GPIO_1,
    output wire        VGA_CLK, VGA_HS, VGA_VS, VGA_BLANK_N, VGA_SYNC_N,
    output wire [7:0]  VGA_R, VGA_G, VGA_B
);
    // ---- clocks ------------------------------------------------------------------------------
    wire clk_25, pll_locked;
    wire clk_10;
    video_pll video_pll_u (.refclk(CLOCK_50), .rst(1'b0), .outclk_0(clk_25), .outclk_1(clk_10), .locked(pll_locked));
    wire sccb_clk;
    clock_divider #(.DIVISOR(250)) sccb_clk_u (.clk_in(clk_25), .clk_out(sccb_clk));   // 100 kHz

    // ---- the camera's pins ---------------------------------------------------------------------
    wire       cam_pclk  = GPIO_1[21];
    wire       cam_href  = GPIO_1[22];
    wire       cam_vsync = GPIO_1[23];
    wire [7:0] cam_d     = GPIO_1[19:12];
    wire       cam_reset_n, cam_pwdn, cfg_sioc, hold_sioc;
    assign GPIO_1[20] = clk_10;          // XCLK 10 MHz; the sensor's PLL makes PCLK from it (/2 and x4: 20 MHz at 25 fps; ov7670_config.sv)
    assign GPIO_1[11] = cam_reset_n;     // RESET#
    assign GPIO_1[10] = cam_pwdn;        // PWDN
    // SIO_C (GPIO_1[25]) is assigned below, once cfg_done exists: ov7670_config's, then ov7670_hold's.
    // GPIO_1[24] is SIO_D, driven open-drain from inside ov7670_config and ov7670_hold; every other pin stays an input

    // ---- reset: KEY0 (active low), synchronised into each domain ---------------------------------
    logic [1:0] rs25 = '0, rs_sccb = '0, rs_pclk = '0;
    always_ff @(posedge clk_25)   rs25    <= {rs25[0],    ~KEY[0] | ~pll_locked};
    always_ff @(posedge sccb_clk) rs_sccb <= {rs_sccb[0], ~KEY[0]};
    always_ff @(posedge cam_pclk) rs_pclk <= {rs_pclk[0], ~KEY[0]};
    wire reset25 = rs25[1], reset_sccb = rs_sccb[1], reset_pclk = rs_pclk[1];

    // ---- configure the camera ------------------------------------------------------------------
    wire cfg_done, cfg_error;
    ov7670_config #(.FPS(CAMERA_FPS)) cfg_u (
        .clk(sccb_clk), .reset(reset_sccb), .sioc(cfg_sioc), .siod(GPIO_1[24]),
        .cam_reset_n(cam_reset_n), .cam_pwdn(cam_pwdn), .done(cfg_done), .error(cfg_error));

    // ---- the hold: SW9 up holds the camera's automatic exposure, gain and white balance (COM8 = 0xE0) ------
    // once the picture has settled (2 s after configuration at the earliest); SW9 down lets them run (0xE7).
    wire cam_held, hold_error;
    ov7670_hold hold_u (
        .clk(sccb_clk), .reset(reset_sccb), .cfg_done(cfg_done), .hold(SW[9]),
        .sioc(hold_sioc), .siod(GPIO_1[24]), .held(cam_held), .busy(), .error(hold_error));
    assign GPIO_1[25] = cfg_done ? hold_sioc : cfg_sioc;   // SIO_C: ov7670_config's until it is done (both idle high)

    // ---- capture the stream (PCLK domain) --------------------------------------------------------
    wire        frame_start, px_valid;
    wire [15:0] px;
    wire [9:0]  px_x;
    wire [8:0]  px_y;
    ov7670_capture cap_u (
        .pclk(cam_pclk), .vsync(cam_vsync), .href(cam_href), .d(cam_d),
        .frame_start(frame_start), .valid(px_valid), .pixel(px), .x(px_x), .y(px_y));

    // ---- one picture in memory: written at PCLK, read at clk_25 ----------------------------------
    wire [8:0]  rd_x;
    wire [7:0]  rd_y;
    wire [15:0] rd_pixel;
    frame_buffer #(.W(320), .H(240), .DW(16), .DECIMATE(2), .BUFFERS(1), .PACKED(0)) fb_u (   // one 16-bit picture, 150 M10K
        .wr_clk(cam_pclk), .wr_frame_start(frame_start), .wr_valid(px_valid), .wr_x(px_x), .wr_y(px_y), .wr_pixel(px),
        .rd_clk(clk_25), .rd_x(rd_x), .rd_y(rd_y), .rd_pixel(rd_pixel));

    // ---- the frame grab: KEY1 or the PC -> the next whole frame + its numbers -> the memory GRAB -------
    wire [5*32-1:0] stats;                       // your design's numbers go here (frame_stats.sv is an example)
    frame_stats #(.W(320), .H(240)) stats_u (
        .clk(cam_pclk), .frame_start(frame_start), .valid(px_valid), .pixel(px), .x(px_x), .y(px_y), .results(stats));
    wire snap_busy, snap_ready;
    frame_snap #(.MODE(SNAP_MODE), .N_RESULTS(5)) snap_u (
        .pclk(cam_pclk), .reset(reset_pclk), .frame_start(frame_start), .px_valid(px_valid), .pixel(px), .x(px_x), .y(px_y),
        .results(stats), .trigger(~KEY[1]), .busy(snap_busy), .ready(snap_ready));

    // ---- show it -----------------------------------------------------------------------------------
    wire [29:0] st_data;
    wire        st_sop, st_eop, st_valid, st_ready;
    camera_display #(.H_RES(640), .V_RES(480), .W(320), .H(240)) disp_u (
        .clk(clk_25), .reset(reset25), .hold_enable(1'b1), .rd_x(rd_x), .rd_y(rd_y), .rd_pixel(rd_pixel),
        .data(st_data), .startofpacket(st_sop), .endofpacket(st_eop), .valid(st_valid), .ready(st_ready));

    vga_sink vga_u (
        .clk_clk(clk_25), .reset_reset_n(~reset25),
        .video_in_data(st_data), .video_in_startofpacket(st_sop), .video_in_endofpacket(st_eop),
        .video_in_valid(st_valid), .video_in_ready(st_ready),
        .vga_CLK(VGA_CLK), .vga_HS(VGA_HS), .vga_VS(VGA_VS), .vga_BLANK(VGA_BLANK_N), .vga_SYNC(VGA_SYNC_N),
        .vga_R(VGA_R), .vga_G(VGA_G), .vga_B(VGA_B));

    // ---- status LEDs ---------------------------------------------------------------------------------
    logic frame_toggle = 1'b0;
    always_ff @(posedge cam_pclk) if (frame_start) frame_toggle <= ~frame_toggle;
    assign LEDR = {cam_held, hold_error, 3'b0, snap_busy, snap_ready, frame_toggle, cfg_error, cfg_done};
endmodule
