/*
 *  ov7670_config.sv -- put the camera into a known state over the SCCB, then get out of the way.
 *
 *  The OV7670's control bus, SCCB, is I2C with a different name: START, the ID byte 0x42 (7-bit
 *  address 0x21 + write), one register address byte, one data byte, a ninth clock after each byte,
 *  STOP. That is exactly the transaction i2c_master.sv (Lesson 3, Task 2.1) sends to the WM8731,
 *  so the same master is used here unchanged; only the address and the list of writes differ.
 *  SCCB calls the ninth bit "don't care" rather than ACK, but the OV7670 pulls it low, so the master
 *  sees an ACK and `error` stays 0.
 *
 *  Sequence, and why (datasheet Table 4, p.6):
 *    1. hold RESET# low for T_RESET, release it, and wait T_SETTLE: the chip needs up to 1 ms
 *       after any reset before it answers (tS:RESET). Writes sent earlier are lost, and the camera
 *       ends up half configured (a green picture until you press reset);
 *    2. write COM7 = 0x80, the software reset, and wait T_SETTLE again (counted from the start of
 *       that write, so about 1.7 ms after its STOP);
 *    3. write the rest of the ROM, one register per transaction, sending a write that got no
 *       acknowledge again before the next one (a wire off, or XCLK not running: the chip needs its
 *       clock to answer);
 *    4. `done` goes high once the last write has been acknowledged, and stays high. The video port
 *       has been streaming since step 1; it just streams the *configured* format from here on.
 *
 *  Changing the registers. Nothing you write is permanent. The registers go back to their defaults
 *  at power-up and whenever RESET# is pulsed. This module pulses RESET# at start-up and at every
 *  press of KEY0 (top_level.sv), and then sends the whole list again. The datasheet warns of damage
 *  only beyond its absolute maximum ratings (Table 2), which are voltages and temperatures, not
 *  register values. Some values do stop the picture until you take them out and reset the camera:
 *    - COM2 bit 4, soft sleep;
 *    - a test pattern instead of the picture (COM7 bit 1, COM17 bit 3, or bit 7 of SCALING_XSC or
 *      SCALING_YSC);
 *    - a format, size or sync polarity that ov7670_capture.sv does not expect (COM7, COM15, COM10,
 *      COM14, and the scaling and window registers);
 *    - a PCLK faster than the 40 MHz the design is constrained for (CLKRC, DBLV and COM14's divider
 *      set it).
 *  Try a change in simulation first. In the configuration bench (tb/ov7670_config_tb.sv) the camera
 *  model reports every write in words, in its [OV7670 ...] lines, and the bench FAILs on purpose, and
 *  says why, when the format, size, sync polarity or PCLK is not the course's, or when a test pattern
 *  is on.
 *
 *  The frame rate, FPS: 25 frames a second (the default) or 50. It sets the camera's clock (CLKRC's
 *  prescaler) and the banding filter's two values: three entries of the list (the table below), and
 *  nothing else in the design, since ov7670_capture.sv follows VSYNC and HREF whatever the rate.
 *  top_level.sv sets it (CAMERA_FPS). Measured on a board: at 25 (PCLK 20 MHz) the picture is clean
 *  and each frame has up to 40 ms to expose. 50 (40 MHz) overclocks the sensor: its readout runs past
 *  its rating (the datasheet gives VGA at 30 frames a second, about 24 MHz), plain surfaces show faint
 *  fixed horizontal bands, and a frame has only 20 ms to expose; in return frames come twice as often,
 *  with less tearing and less latency.
 *
 *  Clocked by the SCCB bit clock (100 kHz from clock_divider.sv), like set_audio_encoder.sv, so
 *  the millisecond waits are counts of a few hundred.
 */
module ov7670_config #(
    parameter int SCCB_CLK_HZ = 100_000,   // the clock this module and the I2C master run on
    parameter bit TUNING      = 1,         // 1: also send OmniVision's picture-quality values (0: only the first N_CORE)
    parameter int  FPS        = 25         // frames a second: 25 (the default) or 50 (the table below)
) (
    input  logic clk,                      // SCCB bit clock, <= 400 kHz (Table 4)
    input  logic reset,                    // synchronous, active high: starts the sequence again
    output logic sioc,                     // camera SIO_C
    inout  wire  siod,                     // camera SIO_D (open drain, with a pull-up)
    output logic cam_reset_n,              // camera RESET# (low = reset)
    output logic cam_pwdn,                 // camera PWDN (high = power down)
    output logic done,                     // all writes acknowledged
    output logic error                     // the last write was not acknowledged (it is being retried)
);
    localparam int T_RESET  = SCCB_CLK_HZ / 1000;          // 1 ms with RESET# low
    localparam int T_SETTLE = 2 * SCCB_CLK_HZ / 1000;      // 2 ms: tS:RESET is "up to 1 ms"

    // ---- the frame rate: FPS sets three entries of the list -------------------------------------------
    // FPS must be 25 or 50. Anything else stops the compile here: Quartus and Verilator then report that the module
    // FPS_must_be_25_or_50 does not exist. (Quartus 18.1 cannot do this with $error.)
    generate
        if (FPS != 25 && FPS != 50) begin : fps_must_be_25_or_50
            FPS_must_be_25_or_50 stop_here ();
        end
    endgenerate
    // XCLK is 10 MHz. PCLK = XCLK / the prescaler (CLKRC[5:0] + 1) x the PLL (DBLV[7:6]); a line is 1,568 PCLKs and a
    // frame 510 lines. The banding filter counts its step in lines, so its two values follow the line's length: BD50ST
    // is the lines in 10 ms (50 Hz mains: the lights flicker at 100 Hz), BD60ST the lines in 8.33 ms (60 Hz mains).
    //     FPS   PCLK     DBLV           CLKRC       a line      BD50ST        BD60ST
    //     25    20 MHz   0x4A: PLL x4   0x81: /2    78.40 us    128 (0x80)    106 (0x6A)
    //     50    40 MHz   0x4A: PLL x4   0x80: /1    39.20 us    255 (0xFF)    213 (0xD5)
    // Both were tested on a board: PCLK exactly as in the table, and every line of 50 frames whole.
    localparam logic [7:0] CLKRC_VALUE  = (FPS == 50) ? 8'h80 : 8'h81;
    localparam logic [7:0] BD50ST_VALUE = (FPS == 50) ? 8'hFF : 8'h80;
    localparam logic [7:0] BD60ST_VALUE = (FPS == 50) ? 8'hD5 : 8'h6A;

    // ---- the register list: {address, value} ------------------------------------------------
    // Every entry is one SCCB write, sent in this order. The first entry, COM7 = 0x80, resets every
    // register to its default, and the default output is YUV. The fifth and sixth entries, COM7 = 0x04
    // and COM15 = 0xD0, then select RGB565. RGB565 is what the camera sends.
    // The first N_CORE entries set the picture's format, size and timing. The rest, the tuning and colour
    // blocks below, are OmniVision's recommended values as the Linux ov7670 driver sends them: they tune
    // the picture. TUNING = 0 leaves them out.
    localparam int N_CORE = 17;
    localparam int N_ALL  = 78;
    localparam logic [15:0] ROM [0:N_ALL-1] = '{
        16'h1280,   // COM7   the software reset puts every register back to its default, so the output is YUV for now.
        //                    COM7 = 0x04 and COM15 = 0xD0 below select RGB565, and that is what the camera sends.
        //                    (The sequencer waits T_SETTLE after this entry.)
        16'h3A04,   // TSLB   no negative image, normal UV order, no automatic window
        {8'h11, CLKRC_VALUE},   // CLKRC  bit 7 set; the prescaler /2 (/1 at 50 fps) \  XCLK 10 MHz from the FPGA, /2 and x4 in the
        16'h6B4A,               // DBLV   PLL x4, regulator on                       /  sensor: PCLK 20 MHz (the table above)
        // CLKRC bit 7 stays set, as it is after a reset. Table 5 calls it reserved, but on the chip, clearing it halves the
        // clock (measured on a board: CLKRC 0x00 with DBLV 0x4A gave 20 MHz, not 40). The PLL's x8 is not used: on a board it
        // did not lock (from 10 MHz, PCLK wandered between 40 and 42 MHz; from 3.3 MHz, CLKRC 0x82, it ran at 25.7 MHz and
        // the picture was garbage). Nor is x6: behind the prescaler at /2 (DBLV 0x8A, CLKRC 0x81) it made 30 MHz, but the
        // capture then slipped a byte on some rows.
        // 25 frames a second is the default: on a board the picture is clean at 20 MHz. At 40 MHz (50 fps) the sensor's
        // readout runs past its rating (the datasheet gives VGA at 30 frames a second, about 24 MHz) and plain surfaces show
        // faint fixed horizontal bands, four to six times stronger than at 20 MHz with the exposure and gain fixed, though
        // the pixels' noise is the same. 50 is as fast as the banding filter goes: 10 ms of mains flicker is 255 lines at
        // 40 MHz, the most BD50ST's 8 bits hold. XCLK stays at 10 MHz: x4 from 25 MHz would be 100 MHz.
        16'h1204,   // COM7   RGB output, VGA, colour bar off
        16'h40D0,   // COM15  RGB565, output range 00..FF                       (0x10 would be RGB565 with range 10..F0)
        16'h1714,   // HSTART \  window columns 160..16 (wrapping at 784): 640 wide. A window from column 140
        16'h1802,   // HSTOP   } puts the sensor's dummy columns at the left of the picture as static coloured
        16'h3280,   // HREF   /  bars; 158 and 159 leave a dark column, and 160 at most a faint one
        16'h1902,   // VSTRT  \  window rows 11..491: 480 high. The Linux driver's VREF 0x0A starts the window at row 10,
        16'h1A7A,   // VSTOP   } but the chip sends row 10 as a dark blue line, not picture (measured on a board), so the
        16'h030F,   // VREF   /  window starts a row lower: VREF[1:0] = 3 (start 2 x 4 + 3), VREF[3:2] = 3 (stop 0x7A x 4 + 3)
        16'h1E37,   // MVFP   mirror + vertical flip: the module hangs upside down on the loom (0x07 = neither)
        // Room lights flicker at 100 Hz (50 Hz mains). Unless the exposure is a whole number of
        // 10 ms periods the picture's brightness beats against it; the banding filter makes it so.
        // The default COM8 (0x8F) has the filter OFF, and then the picture pulses.
        16'h13E7,   // COM8   fast AEC/AGC, AEC step unlimited (bit 6), BANDING FILTER on (bit 5), AGC, AWB, AEC
        16'h3B0A,   // COM11  filter for 50 Hz mains (bit 3); exposure may drop below the filter's step in bright light (bit 1)
        {8'h9D, BD50ST_VALUE},  // BD50ST 50 Hz filter value = the lines in 10 ms: 10 ms / 78.4 us = 128 at 25 fps (the table above; the default 0x99 = 153 is for 24 MHz XCLK at 30 fps)
        {8'h9E, BD60ST_VALUE},  // BD60ST 60 Hz value, the lines in 8.33 ms: 106 at 25 fps, in case COM11 is set to 60 Hz
        // ---- tuning: OmniVision's recommended values, as the Linux ov7670 driver sends them ----
        // The values are from the driver's ov7670_default_regs, "the default register settings, as obtained from
        // OmniVision". COM9 and COM13 are from its YUV format table, ov7670_fmt_yuv422. The datasheet does not
        // document most of these registers. Many are reserved registers, and several values set reserved bits to
        // something other than the Table 5 default. This is deliberate: they are OmniVision's values. TUNING = 0
        // leaves out this block and the colour block, so you can compare the two pictures. Each entry gives its
        // Table 5 default, or XX where Table 5 gives none.
        16'h1448,   // COM9    AGC ceiling 32x (bits 6:4), as the default; reserved bit 1 clear (default 0x4A)
        16'h3DC0,   // COM13   gamma (bit 7) and UV saturation auto-adjust (bit 6) on; reserved bit 3 clear (default 0x88)
        16'h0E61,   // COM5    reserved (default 0x01)
        16'h0F4B,   // COM6    timing reset on a format change (bit 1), as the default; reserved bit 3 set (default 0x43)
        16'h1602,   //         reserved (default XX)
        16'h2291,   // ADCCTR2 reserved (default 0x01)
        16'h2907,   //         reserved (default XX)
        16'h330B,   // CHLF    reserved (default 0x08)
        16'h350B,   //         reserved (default XX)
        16'h371D,   // ADC     reserved (default 0x3F)
        16'h3871,   // ACOM    reserved (default 0x01)
        16'h392A,   // OFON    reserved (default 0x00)
        16'h3C78,   // COM12   HREF option (bit 7) left at 0, as the default; reserved bit 4 set (default 0x68)
        16'h4D40,   //         reserved (default XX)
        16'h4E20,   //         reserved (default XX)
        16'h7410,   // REG74   digital gain from bits 1:0 (bit 4), which are 00, so bypassed (default 0x00)
        16'h8D4F,   //         reserved (default XX)
        16'hB084,   //         reserved (default XX)
        16'hB10C,   // ABLC1   automatic black level calibration on (bit 2); reserved bit 3 set (default 0x00)
        16'hB20E,   //         reserved (default XX)
        16'hB382,   // THL_ST  black level calibration target (default 0x80)
        16'hB80A,   //         reserved (default XX)
        // ---- colour: white balance, gains and the colour matrix, with the driver's edge, de-noise and other values ----
        // These are from ov7670_default_regs too, except COM16, which is 0x18 where the driver has 0x38 (see its entry).
        // The white-balance values and gains belong with the matrix. Without them the matrix gives a green cast.
        // The matrix, like COM9's 32x gain ceiling above, is the one in the driver's YUV table. Its RGB565 table has
        // a 16x ceiling and the matrix B3 B3 00 3D A7 E4 instead. This list sends RGB565 with the YUV table's matrix
        // and ceiling. AWBC1..6 (0x43..0x48), which the driver also writes, are not sent.
        16'h5988,   //         reserved, AWB control (default XX)
        16'h5A88,   //         reserved, AWB control (default XX)
        16'h5B44,   //         reserved, AWB control (default XX)
        16'h5C67,   //         reserved, AWB control (default XX)
        16'h5D49,   //         reserved, AWB control (default XX)
        16'h5E0E,   //         reserved, AWB control (default XX)
        16'h6C0A,   // AWBCTR3 \
        16'h6D55,   // AWBCTR2  } the auto white balance's control values; Table 5 does not describe their bits
        16'h6E11,   // AWBCTR1 /  (defaults 0x02, 0x55, 0xC0)
        16'h6F9F,   // AWBCTR0  (default 0x9A; 0x9E would be the "advanced" AWB)
        16'h6A40,   // GGAIN   green channel AWB gain (default 0x00)
        16'h0140,   // BLUE    blue channel AWB gain (default 0x80)
        16'h0260,   // RED     red channel AWB gain (default 0x80)
        16'h4F80,   // MTX1 \
        16'h5080,   // MTX2  |
        16'h5100,   // MTX3  } the colour matrix: about twice the chip's default saturation
        16'h5222,   // MTX4  |  (defaults 0x40, 0x34, 0x0C, 0x17, 0x29, 0x40)
        16'h535E,   // MTX5  |
        16'h5480,   // MTX6 /
        16'h589E,   // MTXS    auto contrast centre on (bit 7); matrix signs as the default (0x1E)
        16'h4118,   // COM16   AWB gain enable, de-noise auto-adjust; NOT the edge-enhancement auto-adjust (0x38), which over-sharpens
        16'h3F00,   // EDGE    edge enhancement 0, as the default (raise a little, 1..4, for some sharpening back)
        16'h7505,   // REG75   edge enhancement lower limit (default 0x0F)
        16'h76E1,   // REG76   black and white pixel correction on (bits 7, 6); reserved bit 5 set (default 0x01)
        16'h4C00,   // DNSTH   de-noise threshold, as the default (0x00)
        16'h7701,   // REG77   de-noise offset (default 0x10)
        16'h4B09,   // REG4B   UV average on (bit 0); reserved bit 3 set (default 0x00)
        16'hC960,   // SATCTR  UV saturation control minimum, bits 7:4 (default 0xC0)
        16'h5640,   // CONTRAS contrast, as the default (0x40)
        16'h3411,   // ARBLM   reserved, as the default (0x11)
        16'hA488,   // NT_CTRL bit 3 (auto frame rate adjustment control) and reserved bit 7 set (default 0x00)
        16'h9600,   //         reserved (default XX)
        16'h9730,   //         reserved (default XX)
        16'h9820,   //         reserved (default XX)
        16'h9930,   //         reserved (default XX)
        16'h9A84,   //         reserved (default XX)
        16'h9B29,   //         reserved (default XX)
        16'h9C03,   //         reserved (default XX)
        16'h7804    //         reserved (default XX)
    };
    localparam int N = TUNING ? N_ALL : N_CORE;

    // ---- the I2C master from Lesson 3 --------------------------------------------------------
    logic [15:0] cmd;
    logic        valid, ready, m_error;
    i2c_master u_master (
        .clk(clk), .i2c_scl(sioc), .i2c_sda(siod),
        .slav_addr(7'h21), .read_not_write(1'b0), .reg_addr(cmd[15:8]),
        .write_data(cmd[7:0]), .write_valid(valid), .write_ready(ready),
        .read_data(), .read_valid(), .read_ready(1'b1), .error(m_error));

    // ---- the sequencer ---------------------------------------------------------------------------
    // The master takes a command in its idle cycle (`ready` and `valid` together) and reports whether the
    // write was acknowledged (`m_error`) in its next idle cycle: the same cycle in which it takes the next
    // command. So NEXT and LOAD happen while a write is being sent, and WAIT has the next entry on offer when
    // the master comes back: it never waits for the sequencer, and a write takes 32 clocks. The write it comes
    // back from is therefore the entry BEFORE `index`, and `refused` is the verdict on that one. (Taking
    // `m_error` to be about the entry on offer would never send a refused write again, would send the entry
    // after it twice, and would raise `done` as the last write begins.) While `refused` is high,
    // `valid` stays low so that the master does not take the next entry, `index` steps back to the refused
    // one, and LOAD sends it again. The verdict arrives in WAIT; after the software reset, in SETTLE (which
    // begins while the reset is still being sent); and after the last entry in LAST, which waits for it so
    // that `done` means that every write was acknowledged.
    enum logic [2:0] {RESET_LOW, SETTLE, LOAD, WAIT, NEXT, LAST, DONE} state = RESET_LOW, next_state;
    logic [$clog2(N_ALL)-1:0] index = '0;   // the ROM entry being loaded or offered; the master is sending the one before
    logic [$clog2(T_SETTLE+1)-1:0] wait_count = '0;
    logic settle_after;                     // the entry just sent was the software reset
    logic refused;                          // the master is back from the entry before `index`, and it was not acknowledged

    assign settle_after = (ROM[index] == 16'h1280);
    assign refused      = ready && m_error && (index != '0);   // (index 0: nothing sent since `reset`, which may have cut a write short)

    always_comb begin
        next_state = state;
        case (state)
            RESET_LOW: next_state = (wait_count == T_RESET - 1)  ? SETTLE : RESET_LOW;
            SETTLE:    next_state = (wait_count == T_SETTLE - 1 || refused) ? LOAD : SETTLE;
            LOAD:      next_state = WAIT;
            WAIT:      next_state = !ready ? WAIT : (refused ? LOAD : NEXT);   // no acknowledge: send that entry again
            NEXT:      next_state = (index == N - 1) ? LAST : (settle_after ? SETTLE : LOAD);
            LAST:      next_state = !ready ? LAST : (refused ? LOAD : DONE);
            DONE:      next_state = DONE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= RESET_LOW; index <= '0; wait_count <= '0;
        end else begin
            state <= next_state;
            case (state)
                RESET_LOW, SETTLE: wait_count <= (next_state == state) ? wait_count + 1'b1 : '0;
                LOAD:              cmd <= ROM[index];
                NEXT:              index <= index + 1'b1;
                default: ;
            endcase
            if (refused) index <= index - 1'b1;      // back to the entry that was refused
        end
    end

    assign valid       = (state == WAIT) && !refused;
    assign cam_reset_n = (state != RESET_LOW);
    assign cam_pwdn    = 1'b0;
    assign done        = (state == DONE);
    assign error       = m_error;

endmodule
