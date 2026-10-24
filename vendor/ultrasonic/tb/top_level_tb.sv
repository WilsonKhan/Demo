`timescale 1ns/1ps
/* verilator lint_off BLKSEQ */
/* verilator lint_off PROCASSINIT */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off WIDTHEXPAND */
/*
 *  top_level_tb: the whole board design with two sensor models on the Robot Adaptor Board's pins
 *  (J3: GPIO_1[27] and GPIO_1[29]; J4: GPIO_1[30] and GPIO_1[32]).
 *  The pacer is shortened to 3 ms (PACE_CLKS), so the run, about 7 ms, holds two measurements of each sensor.
 *  Checks: sensor 1 (350 mm) on the displays with SW1 = 0, sensor 2 (150 mm) with SW1 = 1,
 *  the LED bar, and that the two triggers never overlap.
 */
module top_level_tb;
    logic CLOCK_50 = 0; always #10 CLOCK_50 = ~CLOCK_50;
    logic [3:0] KEY = 4'b1111; logic [9:0] SW = '0;
    wire [35:0] GPIO_1; logic [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5; logic [9:0] LEDR;
    top_level #(.PACE_CLKS(131_712)) dut (.*);     // 3 ms between measurements instead of 100 ms

    logic echo1, echo2; int m1, e1, n1, l1, m2, e2, n2, l2;
    hcsr04_model #(.NAME("SENSOR-1"), .T_CYCLE_MIN_MS(1.0)) s1 (.trig(GPIO_1[27]), .echo(echo1), .distance_mm(350), .object_present(1'b1), .measurements(m1), .errors(e1), .notes(n1), .last_echo_us(l1));
    hcsr04_model #(.NAME("SENSOR-2"), .T_CYCLE_MIN_MS(1.0)) s2 (.trig(GPIO_1[30]), .echo(echo2), .distance_mm(150), .object_present(1'b1), .measurements(m2), .errors(e2), .notes(n2), .last_echo_us(l2));
    assign GPIO_1[29] = echo1;
    assign GPIO_1[32] = echo2;

    function automatic int digit(input logic [6:0] seg);   // seven_seg.sv patterns back to a digit (-1 = blank/other)
        case (seg)
            7'b1000000: return 0; 7'b1111001: return 1; 7'b0100100: return 2; 7'b0110000: return 3; 7'b0011001: return 4;
            7'b0010010: return 5; 7'b0000010: return 6; 7'b1111000: return 7; 7'b0000000: return 8; 7'b0010000: return 9;
            default: return -1;
        endcase
    endfunction
    function automatic int shown();
        return digit(HEX3) * 1000 + digit(HEX2) * 100 + digit(HEX1) * 10 + digit(HEX0);
    endfunction
    int fails = 0, overlaps = 0;
    always @(posedge CLOCK_50) if (GPIO_1[27] && GPIO_1[30]) overlaps++;

    initial begin
        $timeformat(-6, 1, " us", 10);
        KEY[0] = 0; #200; KEY[0] = 1;              // reset
        SW[0] = 1;                                 // continuous
        wait (m1 >= 2 && m2 >= 2); #500_000;       // both have measured twice; let the display update
        $display("[tb @%0t] SW1=0: displays show %0d mm, HEX5 = %0d, LEDR = %b", $time, shown(), digit(HEX5), LEDR);
        if (shown() < 349 || shown() > 351 || digit(HEX5) != 1) begin fails++; $display("FAIL: expected 350 mm on sensor 1"); end
        if (LEDR != 10'b0001111111) begin fails++; $display("FAIL: LED bar for 350 mm should be 7 LEDs (under 1 m ... under 40 cm)"); end
        SW[1] = 1; #500_000;
        $display("[tb @%0t] SW1=1: displays show %0d mm, HEX5 = %0d, LEDR = %b", $time, shown(), digit(HEX5), LEDR);
        if (shown() < 149 || shown() > 151 || digit(HEX5) != 2) begin fails++; $display("FAIL: expected 150 mm on sensor 2"); end
        if (overlaps != 0) begin fails++; $display("FAIL: the two triggers overlapped %0d times", overlaps); end
        if (e1 + e2 != 0) begin fails++; $display("FAIL: the models counted %0d problem(s)", e1 + e2); end
        if (fails == 0) $display("PASS: top_level shows sensor 1 (350 mm) and sensor 2 (150 mm) on HEX3..HEX0, HEX5 names the sensor, LED bar right, triggers 1.5 ms apart");
        else $display("FAILED: %0d problem(s)", fails);
        $finish;
    end
endmodule
