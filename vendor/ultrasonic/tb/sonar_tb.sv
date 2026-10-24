`timescale 1ns/1ps
/* verilator lint_off BLKSEQ */
/* verilator lint_off PROCASSINIT */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off WIDTHEXPAND */
/*
 *  sonar_tb: sonar_range against hcsr04_model.
 *
 *  Part 1: walls at 100, 1000 and 3000 mm, then nothing in range, then 500 mm. The
 *          reading must be within 1 mm of what the model was given: at 43.904 MHz there
 *          are exactly 256 clocks per mm of distance (2 mm round trip / 343 m/s = 5.831 us),
 *          so count >> 8 is millimetres. The shift drops the fraction of a millimetre, so a
 *          clock a few ppm slow reads 1 mm short, and this bench's clock is 45 ppm slow
 *          (#11.3885 becomes 11.389 ns at 1 ps precision). "Nothing in range" must give the
 *          driver's saturated value.
 *  Part 2: a bad driver (a 2 us trigger, a trigger during the echo, then a re-trigger about
 *          18 ms after the one before) against a second model instance, to show what the
 *          model says.
 *  The model's 60 ms cycle rule is relaxed to 1 ms in part 1 to keep the run short.
 */
module sonar_tb;
    logic clk = 0;
    always #11.3885 clk = ~clk;                     // 43.904 MHz, as sonar_pll makes it
    logic rst = 1, start = 0, echo, trig, valid, ready;
    logic [11:0] distance;
    int wall = 100; logic present = 1;
    int measurements, errors, notes, last_echo_us;

    sonar_range dut (.clk, .start_measure(start), .rst, .echo, .trig, .distance, .ready, .valid);
    hcsr04_model #(.T_CYCLE_MIN_MS(1.0)) sensor (.trig, .echo, .distance_mm(wall), .object_present(present),
                                                 .measurements, .errors, .notes, .last_echo_us);

    // ---- part 2: a bad driver on its own model ----
    logic bad_trig = 0, bad_echo;
    int bad_meas, bad_err, bad_notes, bad_last;
    hcsr04_model #(.NAME("HCSR04-2")) sensor2 (.trig(bad_trig), .echo(bad_echo), .distance_mm(800), .object_present(1'b1),
                                                .measurements(bad_meas), .errors(bad_err), .notes(bad_notes), .last_echo_us(bad_last));

    int fails = 0, valids = 0;
    logic [11:0] got;
    always @(posedge clk) if (valid) begin valids++; got = distance; end

    // Ask for one measurement: hold start_measure until the driver has left IDLE (ready drops),
    // as a held KEY3 would. After the timeout case the driver stays in IDLE until ECHO falls.
    task automatic measure(input int d, input logic obj, input int expect_mm, input string what);
        int v0 = valids;
        wall = d; present = obj;
        @(posedge clk); start = 1;
        wait (!ready); @(posedge clk); start = 0;
        wait (valids == v0 + 1);
        @(posedge clk);
        // A wall can read 1 mm short: the shift drops the fraction of a millimetre, and this bench's
        // clock is 45 ppm slow (see the top). Tolerated here.
        if (got == expect_mm || got == expect_mm - 1)
            $display("[tb @%0t] %s: driver reads %0d mm (%s)  OK", $time, what, got,
                     obj ? $sformatf("model was given %0d mm", d) : "model was given no object");
        else begin
            fails++;
            $display("[tb @%0t] FAIL %s: driver reads %0d mm, expected %0d (or 1 less)", $time, what, got, expect_mm);
        end
    endtask

    initial begin
        $timeformat(-6, 1, " us", 10);
`ifdef VERILATOR
        $dumpfile("waveform.fst");
`else
        $dumpfile("waveform.vcd");
`endif
        $dumpvars(0, dut); $dumpvars(0, sensor); $dumpvars(1, sonar_tb);
        repeat (4) @(posedge clk); rst = 0; repeat (4) @(posedge clk);
        $display("=== part 1: the driver against the sensor model ===");
        measure(100,  1, 100,  "wall at 100 mm");
        measure(1000, 1, 1000, "wall at 1000 mm");
        measure(3000, 1, 3000, "wall at 3000 mm");
        measure(5000, 0, 4000, "nothing in range (ECHO times out, the driver caps its count at 23.3 ms = 4000 mm)");
        // The sensor still holds ECHO high until its 38 ms timeout: the driver waits in IDLE.
        measure(500,  1, 500,  "wall at 500 mm, straight after the timeout");
        if (errors != 0) begin fails++; $display("FAIL: the model counted %0d problem(s) with the driver's triggers", errors); end
        if (valids != 5)  begin fails++; $display("FAIL: %0d valid pulses, expected 5", valids); end
        sensor.print_summary();

        $display("=== part 2: what the model says to a bad driver ===");
        bad_trig = 1; #2000; bad_trig = 0;                  // 2 us: too short
        #100_000;
        bad_trig = 1; #10_000; bad_trig = 0;                // 10 us: fine, 800 mm -> 4665 us echo
        #2_000_000;                                         // 2 ms in: the echo is still high
        bad_trig = 1; #10_000; bad_trig = 0;                // trigger during the measurement: ignored
        wait (bad_meas == 1);
        #(20_000_000 - 4_665_000 - 2_000_000 - 110_000);    // re-trigger about 18 ms after the previous trigger
        bad_trig = 1; #10_000; bad_trig = 0;
        wait (bad_meas == 2);
        #100_000;
        sensor2.print_summary();
        if (bad_err != 2 || bad_notes != 1) begin fails++; $display("FAIL: the bad driver should have produced 2 problems and 1 note, got %0d and %0d", bad_err, bad_notes); end

        if (fails == 0) $display("PASS: 5 measurements right (100, 1000, 3000 mm, nothing in range -> 4000, then 500 mm), no protocol problems; the bad driver was caught (2 problems, 1 note)");
        else $display("FAILED: %0d problem(s)", fails);
        $finish;
    end
endmodule
