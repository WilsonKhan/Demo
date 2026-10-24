`timescale 1ns/1ps
/*
 *  top_level.sv -- two ultrasonic sensors on the DE1-SoC with the Robot Adaptor Board.
 *
 *    CLOCK_50 --> sonar_pll (43.904 MHz) --> sonar_range x2 --> latched distances --> HEX / LEDR
 *
 *  Robot Adaptor Board connectors (stock DE1-SoC pin names, GPIO_1 header; the hardware test's pins):
 *    sensor 1, J3 (pins not marked):              TRIG = GPIO_1[27], ECHO = GPIO_1[29]
 *    sensor 2, J4 (marked 3V3 SPARE0 SPARE1 GND): TRIG = GPIO_1[30] (SPARE0), ECHO = GPIO_1[32] (SPARE1)
 *  Neither connector is keyed, and in this kit the sensors take 3.3 V only: check the polarity before power-up.
 *
 *  Controls:
 *    KEY0        reset
 *    SW0 = 1     measure continuously, 10 times a second
 *    SW0 = 0     measure (at the same rate) only while KEY3 is held
 *    SW1         which sensor the displays show: 0 = sensor 1, 1 = sensor 2
 *    HEX3..HEX0  distance of the selected sensor in mm (4000 = nothing in range; 0000 after a reset, until its first reading)
 *    HEX5        the selected sensor's number; HEX4 blank
 *    LEDR        parking-sensor bar of the selected sensor: 1 LED under 1 m, all 10 under 10 cm
 *
 *  The two sensors are triggered 50 ms apart: fired together, each would hear the
 *  other's chirp. Everything runs in the PLL's clock, so the results need no clock
 *  crossing; ECHO, KEY and SW are asynchronous inputs and are synchronised where
 *  they are used (sonar_range does it for ECHO and start; SW1 only picks a display).
 */
module top_level #(
    parameter int PACE_CLKS = 4_390_400   // 100 ms at 43.904 MHz: the datasheet asks for more than 60 ms between measurements
) (
    input  logic        CLOCK_50,
    input  logic [3:0]  KEY,
    input  logic [9:0]  SW,
    inout  wire  [35:0] GPIO_1,
    output logic [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    output logic [9:0]  LEDR
);
    logic clk, pll_locked;
    sonar_pll u_pll (.refclk(CLOCK_50), .rst(1'b0), .outclk_0(clk), .locked(pll_locked));

    // ---- the pins ----
    logic trig1, trig2;
    assign GPIO_1[27] = trig1;           // J3
    assign GPIO_1[30] = trig2;           // J4, SPARE0
    wire echo1 = GPIO_1[29];             // J3
    wire echo2 = GPIO_1[32];             // J4, SPARE1

    // ---- reset, synchronised ----
    logic [1:0] rs = '0;
    always_ff @(posedge clk) rs <= {rs[0], ~KEY[0] | ~pll_locked};
    wire reset = rs[1];

    // ---- pacing: a start pulse every PACE_CLKS, sensor 2 half a period later ----
    localparam int PW = $clog2(PACE_CLKS);
    logic [PW-1:0] pace = '0;
    logic start1 = 1'b0, start2 = 1'b0;
    always_ff @(posedge clk) begin
        pace   <= (pace == PW'(PACE_CLKS - 1)) ? '0 : pace + 1'b1;
        start1 <= (pace < PW'(16));                                                  // 16 clocks: long enough for sonar_range's synchroniser
        start2 <= (pace >= PW'(PACE_CLKS / 2)) && (pace < PW'(PACE_CLKS / 2 + 16));
    end
    wire measure_enable = SW[0] | ~KEY[3];

    // ---- the two drivers ----
    logic [11:0] dist1, dist2, d1 = '0, d2 = '0;
    logic valid1, valid2, ready1, ready2;
    sonar_range u_sonar1 (.clk, .start_measure(start1 & measure_enable), .rst(reset), .echo(echo1), .trig(trig1),
                          .distance(dist1), .ready(ready1), .valid(valid1));
    sonar_range u_sonar2 (.clk, .start_measure(start2 & measure_enable), .rst(reset), .echo(echo2), .trig(trig2),
                          .distance(dist2), .ready(ready2), .valid(valid2));
    always_ff @(posedge clk) begin
        if (reset) begin
            d1 <= '0;
            d2 <= '0;
        end else begin
            if (valid1) d1 <= dist1;
            if (valid2) d2 <= dist2;
        end
    end

    // ---- displays ----
    logic [1:0] sel; always_ff @(posedge clk) sel <= {sel[0], SW[1]};
    wire [11:0] shown = sel[1] ? d2 : d1;
    display #(.VALUE_WIDTH(12), .DIGITS(4)) u_display (.clk, .value(shown), .display0(HEX0), .display1(HEX1), .display2(HEX2), .display3(HEX3));
    seven_seg u_hex5 (.bcd(sel[1] ? 4'd2 : 4'd1), .segments(HEX5));
    assign HEX4 = 7'b1111111;
    always_comb for (int i = 0; i < 10; i++) LEDR[i] = (shown < 12'((10 - i) * 100));   // LEDR0 under 1 m ... LEDR9 under 10 cm
endmodule
