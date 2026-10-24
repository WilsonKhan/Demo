`timescale 1ns/1ps
/* verilator lint_off PROCASSINIT */
/* verilator lint_off IMPLICITSTATIC */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off BLKSEQ */
/* verilator lint_off MULTIDRIVEN */
/* verilator lint_off SYNCASYNCNET */
/* verilator lint_off REALCVT */
/* verilator lint_off ZERODLY */
// (This file is a simulation model. It is never synthesised, so the lint rules
//  that matter for synthesisable code are relaxed to keep your terminal clean.)
/*
 * ============================================================================
 *  ir_remote_model.sv  --  Behavioural model of the IR remote control and the
 *                          DE1-SoC's IR receiver module (the IRDA_RXD pin)
 * ============================================================================
 *
 *  WHAT IS THIS?
 *  -------------
 *  A *simulation model* of everything between your thumb and the FPGA pin:
 *
 *      thumb --> remote (NEC frame on a 38 kHz carrier) --> air -->
 *      receiver module on the DE1-SoC (band-pass, demodulate, invert) --> IRDA_RXD
 *
 *  On the board you cannot see any of that: the only thing you can probe is
 *  IRDA_RXD, one wire that is HIGH when nothing is happening and LOW for as long
 *  as the receiver hears the 38 kHz carrier. This model drives that wire from a
 *  testbench task ("press Power", "hold CH+ for 400 ms") exactly as the remote
 *  and receiver would, and it also *listens* to the wire with an independent
 *  monitor that decodes every frame back into words, so the log says what an IR
 *  decoder on the FPGA actually had to work with.
 *
 *  Sources:
 *    - NEC infrared transmission protocol (the format the Terasic remote uses):
 *      9 ms lead burst, 4.5 ms space; 32 bits, least significant first, each a
 *      562.5 us burst followed by a 562.5 us space (0) or a 1687.5 us space (1);
 *      a final 562.5 us stop burst; frames 108 ms apart while a key is held, the
 *      later ones being *repeat codes*: 9 ms burst, 2.25 ms space, stop burst.
 *    - The bit order and the checks are the ones Terasic's IR_RECEIVE (the
 *      DE2-115 / DE1-SoC demonstration, rtl/IR_RECEIVE_Terasic.v) implements: bits 0..15 are the remote's
 *      16-bit "custom code", bits 16..23 the key code, bits 24..31 the key code
 *      inverted; a frame is accepted when data[31:24] == ~data[23:16].
 *    - DE1-SoC user manual, IR receiver section: the receiver's output is the
 *      demodulated, inverted envelope (LOW during a burst) on IRDA_RXD.
 *
 *  FIDELITY (what is and is not modelled)
 *  ---------------------------------------
 *  Modelled:      the NEC frame and repeat-code timing; the custom / key /
 *                 inverted-key layout; frames spaced T_FRAME_MS apart while a key
 *                 is held; the receiver's inverted envelope output; with
 *                 CARRIER_MODEL = 1 also the receiver's fixed delay, its
 *                 stretching of the LOW pulse and its refusal to report a burst
 *                 shorter than T_MIN_BURST; an independent monitor that decodes
 *                 the wire and names timing a decoder would choke on.
 *  NOT modelled:  the 38 kHz carrier itself (the FPGA never sees it), the optics
 *                 (range, angle, sunlight), the receiver's AGC, noise, and the
 *                 electrical levels of the pin.
 *
 *  The key names in key_name() come from Terasic's key-code table for the remote
 *  (DE1-SoC User Manual, Table 5-5: Power 0x12, A 0x0F, B 0x13, C 0x10, digits
 *  0..9 = 0x00..0x09, ...). The manual gives no custom code: CUSTOM_CODE
 *  (16'h6B86) is not from it. Neither has been checked against a real remote
 *  yet. Check both on the board: press a key with the Terasic decoder running
 *  and read HEX5..HEX0. A wrong name or custom code never changes a waveform:
 *  the model transmits whatever code the testbench asks for, and the decoder
 *  under test must decode exactly that.
 *
 *  HOW TO USE
 *  ----------
 *    wire irda;
 *    ir_remote_model remote (.irda_rxd(irda));
 *    IR_RECEIVE dut (.iCLK(clk), .iRST_n(rst_n), .iIRDA(irda), ...);
 *    ...
 *    remote.press(8'h12);          // one frame (Power), then idle to the end of the 108 ms slot
 *    remote.press(8'h0F, 20);      // the same with only 20 ms of idle line after it (faster simulation)
 *    remote.hold(8'h1A, 400);      // CH+ held for 400 ms: a frame, then repeat codes every 108 ms
 *    remote.send_raw_frame(32'h00126B86);   // any 32 bits you like (here: a bad inverted byte)
 *    remote.print_summary();
 *
 *  Observation hooks: frames_sent, repeats_sent (what the remote did),
 *  frames_decoded, last_decoded, repeats_decoded, monitor_errors (what the
 *  monitor made of the wire).
 * ============================================================================
 */
module ir_remote_model #(
    parameter logic [15:0] CUSTOM_CODE   = 16'h6B86,   // bit 0 is transmitted first; equals data[15:0] in Terasic's decoder. CHECK AGAINST YOUR REMOTE.
    parameter realtime     T_LEAD_BURST  = 9ms,
    parameter realtime     T_LEAD_SPACE  = 4.5ms,
    parameter realtime     T_REPEAT_SPACE= 2.25ms,
    parameter realtime     T_BIT_BURST   = 562.5us,
    parameter realtime     T_SPACE_0     = 562.5us,
    parameter realtime     T_SPACE_1     = 1687.5us,
    parameter int          T_FRAME_MS    = 108,        // frame-to-frame period while a key is held
    parameter bit          CARRIER_MODEL = 0,          // 1: add the receiver module's delay, pulse stretch and minimum burst
    parameter realtime     T_RX_DELAY    = 200us,      // receiver output lags the burst (typical for 38 kHz receiver modules); keep it >= T_MIN_BURST
    parameter realtime     T_RX_STRETCH  = 30us,       // the LOW pulse ends this much late (the datasheet's pulse-width deviation)
    parameter realtime     T_MIN_BURST   = 200us,      // bursts shorter than this are not reported at all
    parameter bit          VERBOSE       = 1
) (
    output logic        irda_rxd,          // what the FPGA pin sees: HIGH idle, LOW during a burst
    // What the remote did:
    output int          frames_sent,
    output int          repeats_sent,
    // What the monitor decoded from the wire:
    output int          frames_decoded,
    output int          repeats_decoded,
    output logic [31:0] last_decoded,      // the last frame that passed the check: {~key, key, custom[15:0]}, the word Terasic's decoder builds
    output int          monitor_errors
);

    // ------------------------------------------------------------------------
    //  Key names (see the header: Terasic's table, not yet checked on a remote).
    // ------------------------------------------------------------------------
    function automatic string key_name(input logic [7:0] k);
        case (k)
            8'h12: return "Power";
            8'h0F: return "A";
            8'h13: return "B";
            8'h10: return "C";
            8'h00: return "0";
            8'h01: return "1";
            8'h02: return "2";
            8'h03: return "3";
            8'h04: return "4";
            8'h05: return "5";
            8'h06: return "6";
            8'h07: return "7";
            8'h08: return "8";
            8'h09: return "9";
            8'h0C: return "MUTE";
            8'h1A: return "CH+";
            8'h1E: return "CH-";
            8'h1B: return "VOL+";
            8'h1F: return "VOL-";
            8'h11: return "MENU";
            8'h17: return "RETURN";
            8'h16: return "PLAY";
            8'h14: return "ADJUST <";
            8'h18: return "ADJUST >";
            default: return "unknown key";
        endcase
    endfunction

    function automatic logic [31:0] frame_word(input logic [7:0] key);
        return {~key, key, CUSTOM_CODE};
    endfunction

    // ------------------------------------------------------------------------
    //  The remote: an envelope (carrier on/off), and the receiver that turns it
    //  into the pin level.
    // ------------------------------------------------------------------------
    logic carrier_on = 1'b0;     // 1 = the remote's LED is emitting the 38 kHz carrier
    logic key_down   = 1'b0;

    initial begin
        irda_rxd = 1'b1;
        frames_sent = 0; repeats_sent = 0;
        frames_decoded = 0; repeats_decoded = 0; last_decoded = '0; monitor_errors = 0;
    end

    generate
        if (CARRIER_MODEL) begin : g_receiver
            // A receiver module reports a burst T_RX_DELAY after it starts, but only
            // once it has lasted T_MIN_BURST, and lets go T_RX_DELAY + T_RX_STRETCH
            // after it ends. (The delays are far shorter than a bit, so no edge is missed.)
            always @(carrier_on) begin
                if (carrier_on) begin
                    #(T_MIN_BURST);
                    if (carrier_on) begin
                        if (T_RX_DELAY > T_MIN_BURST) #(T_RX_DELAY - T_MIN_BURST);
                        irda_rxd = 1'b0;
                    end
                end else begin
                    #(T_RX_DELAY + T_RX_STRETCH);
                    irda_rxd = 1'b1;
                end
            end
        end else begin : g_ideal
            always @(carrier_on) irda_rxd = ~carrier_on;
        end
    endgenerate

    // ---- the bit-level transmitter -----------------------------------------
    task automatic burst(input realtime t_on, input realtime t_off);
        carrier_on = 1'b1;
        #(t_on);
        carrier_on = 1'b0;
        #(t_off);
    endtask

    // Send 32 bits, least significant first, framed the NEC way.
    task automatic send_word(input logic [31:0] word, input string what);
        realtime t0 = $realtime;
        burst(T_LEAD_BURST, T_LEAD_SPACE);
        for (int i = 0; i < 32; i++)
            burst(T_BIT_BURST, word[i] ? T_SPACE_1 : T_SPACE_0);
        burst(T_BIT_BURST, 0);                       // the stop burst
        frames_sent++;
        if (VERBOSE) $display("[IR @%0t] remote: %s: word 0x%08X sent (custom 0x%04X, key 0x%02X, ~key 0x%02X) in %0.2f ms",
                              $time, what, word, word[15:0], word[23:16], word[31:24], ($realtime - t0) / 1ms);
    endtask

    task automatic send_repeat();
        burst(T_LEAD_BURST, T_REPEAT_SPACE);
        burst(T_BIT_BURST, 0);
        repeats_sent++;
        if (VERBOSE) $display("[IR @%0t] remote: repeat code sent (key still held)", $time);
    endtask

    // Wait until the current T_FRAME_MS slot (started at t_slot) has elapsed.
    task automatic wait_slot_end(input realtime t_slot);
        realtime t_end = t_slot + T_FRAME_MS * 1ms;
        if ($realtime < t_end) #(t_end - $realtime);
    endtask

    // ------------------------------------------------------------------------
    //  Testbench interface
    // ------------------------------------------------------------------------
    // One press: a frame, then the wire idles for the rest of the frame period
    // (108 ms: a thumb cannot press twice faster than that). A testbench in a
    // hurry can pass a shorter idle_ms, down to 10 ms (Terasic's decoder needs
    // 0.4 ms of idle line after a frame, but 9.44 ms after a repeat code).
    task automatic press(input logic [7:0] key, input int idle_ms = T_FRAME_MS);
        realtime t_slot = $realtime;
        key_down = 1'b1;
        if (VERBOSE) $display("[IR @%0t] remote: key 0x%02X (%s) pressed", $time, key, key_name(key));
        send_word(frame_word(key), $sformatf("key 0x%02X (%s)", key, key_name(key)));
        key_down = 1'b0;
        if (idle_ms >= T_FRAME_MS) wait_slot_end(t_slot); else #(idle_ms * 1ms);
    endtask

    // Hold a key for `ms` milliseconds: a frame, then a repeat code at every
    // T_FRAME_MS boundary while the key is still down.
    task automatic hold(input logic [7:0] key, input int ms);
        realtime t_press = $realtime;
        realtime t_slot  = $realtime;
        key_down = 1'b1;
        if (VERBOSE) $display("[IR @%0t] remote: key 0x%02X (%s) pressed and held for %0d ms", $time, key, key_name(key), ms);
        send_word(frame_word(key), $sformatf("key 0x%02X (%s)", key, key_name(key)));
        wait_slot_end(t_slot);
        while (key_down && ($realtime - t_press) < ms * 1ms) begin
            t_slot = $realtime;
            send_repeat();
            wait_slot_end(t_slot);
        end
        key_down = 1'b0;
        if (VERBOSE) $display("[IR @%0t] remote: key 0x%02X (%s) released", $time, key, key_name(key));
    endtask

    // Press and hold in the background (fork), until release_key() is called.
    task automatic hold_start(input logic [7:0] key);
        key_down = 1'b1;
        fork
            begin
                realtime t_slot = $realtime;
                if (VERBOSE) $display("[IR @%0t] remote: key 0x%02X (%s) pressed (held until release_key())", $time, key, key_name(key));
                send_word(frame_word(key), $sformatf("key 0x%02X (%s)", key, key_name(key)));
                wait_slot_end(t_slot);
                while (key_down) begin
                    t_slot = $realtime;
                    send_repeat();
                    wait_slot_end(t_slot);
                end
            end
        join_none
    endtask

    task automatic release_key();
        if (key_down && VERBOSE) $display("[IR @%0t] remote: key released", $time);
        key_down = 1'b0;
    endtask

    // Any 32-bit word, for testing a decoder's checks (e.g. a wrong inverted byte).
    task automatic send_raw_frame(input logic [31:0] word, input int idle_ms = T_FRAME_MS);
        realtime t_slot = $realtime;
        send_word(word, "raw frame");
        if (idle_ms >= T_FRAME_MS) wait_slot_end(t_slot); else #(idle_ms * 1ms);
    endtask

    // ------------------------------------------------------------------------
    //  The monitor: decodes the wire from its edges, independently of the
    //  transmitter above, and says what a decoder would have seen.
    // ------------------------------------------------------------------------
    realtime t_fall = 0, t_rise = 0;
    realtime burst_len = 0;
    logic    have_burst   = 1'b0;   // a burst has ended and its length is known
    logic    lead_pending = 1'b0;   // the last burst was a 9 ms lead: the next space decides frame vs repeat
    logic    in_frame     = 1'b0;
    int      mon_bits     = 0;
    logic [31:0] mon_word = '0;
    realtime t_last_stop  = -1;     // end of the last stop burst

    function automatic string us(input realtime t);
        return $sformatf("%0.0f us", t / 1us);
    endfunction

    function automatic void monitor_error(input string msg);
        monitor_errors++;
        $display("[IR @%0t] receiver: TIMING PROBLEM: %s", $time, msg);
    endfunction

    // A burst just ended: measure and classify it.
    always @(posedge irda_rxd) begin
        if (t_fall > 0) begin
            burst_len  = $realtime - t_fall;
            t_rise     = $realtime;
            have_burst = 1'b1;
            if (burst_len > 7ms && burst_len < 11ms) begin
                lead_pending = 1'b1;
                if (in_frame && mon_bits != 0)
                    monitor_error($sformatf("a 9 ms lead burst arrived after only %0d bits of a frame: the frame was cut short", mon_bits));
                in_frame = 1'b0;
                if (t_last_stop >= 0 && (t_fall - t_last_stop) < 9.5ms)
                    monitor_error($sformatf("the next lead burst started %s after the previous stop burst; leave at least 9.5 ms of idle line between frames (after a repeat code, Terasic's decoder is busy for 9.44 ms)", us(t_fall - t_last_stop)));
            end else if (burst_len > 300us && burst_len < 900us) begin
                lead_pending = 1'b0;             // a bit burst or the stop burst; the space that follows decides
                if (!in_frame) t_last_stop = $realtime;   // a bit-sized burst outside a frame is a stop burst
            end else begin
                monitor_error($sformatf("burst of %s is neither a lead burst (9 ms) nor a bit burst (562 us)", us(burst_len)));
                lead_pending = 1'b0;
                in_frame     = 1'b0;
            end
        end
    end

    // A burst is starting: the space before it is now known, so the previous
    // symbol can be decoded.
    always @(negedge irda_rxd) begin
        realtime space_len;
        if (have_burst) begin
            space_len = $realtime - t_rise;
            if (lead_pending) begin
                if (space_len > 3.5ms && space_len < 5.5ms) begin
                    in_frame = 1'b1; mon_bits = 0; mon_word = '0;
                    if (VERBOSE) $display("[IR @%0t] receiver: lead burst %s + space %s: a data frame begins", $time, us(burst_len), us(space_len));
                end else if (space_len > 1.7ms && space_len < 3.0ms) begin
                    repeats_decoded++;
                    if (VERBOSE) $display("[IR @%0t] receiver: lead burst %s + space %s: REPEAT code (the key is still held; no new data follows)", $time, us(burst_len), us(space_len));
                end else begin
                    monitor_error($sformatf("space of %s after a lead burst is neither a frame start (4.5 ms) nor a repeat (2.25 ms)", us(space_len)));
                end
                lead_pending = 1'b0;
            end else if (in_frame) begin
                if (space_len > 300us && space_len < 900us)
                    mon_word[mon_bits] = 1'b0;
                else if (space_len > 1300us && space_len < 2100us)
                    mon_word[mon_bits] = 1'b1;
                else begin
                    monitor_error($sformatf("space of %s after bit %0d is neither a 0 (562 us) nor a 1 (1687 us): frame abandoned", us(space_len), mon_bits));
                    in_frame = 1'b0;
                end
                if (in_frame) begin
                    mon_bits++;
                    if (mon_bits == 32) begin
                        in_frame = 1'b0;
                        if (mon_word[31:24] == ~mon_word[23:16]) begin
                            frames_decoded++;
                            last_decoded = mon_word;     // only a frame that passes the check
                            $display("[IR @%0t] receiver: frame decoded: custom 0x%04X, key 0x%02X (%s), inverted key 0x%02X: check OK  (word 0x%08X)",
                                     $time, mon_word[15:0], mon_word[23:16], key_name(mon_word[23:16]), mon_word[31:24], mon_word);
                        end else begin
                            monitor_errors++;
                            $display("[IR @%0t] receiver: frame decoded: custom 0x%04X, key 0x%02X, inverted key 0x%02X: CHECK FAILED (expected 0x%02X): a decoder must reject this frame  (word 0x%08X)",
                                     $time, mon_word[15:0], mon_word[23:16], mon_word[31:24], ~mon_word[23:16], mon_word);
                        end
                    end
                end
            end
        end
        t_fall = $realtime;
    end

    // ------------------------------------------------------------------------
    task automatic print_summary();
        $display("---------------------------------------------------------------");
        $display("IR model at %0t: remote sent %0d frame(s) and %0d repeat code(s); the monitor decoded %0d good frame(s) and %0d repeat(s), %0d timing/check problem(s).",
                 $time, frames_sent, repeats_sent, frames_decoded, repeats_decoded, monitor_errors);
        if (frames_decoded > 0)
            $display("  last good frame: 0x%08X = custom 0x%04X, key 0x%02X (%s)", last_decoded, last_decoded[15:0], last_decoded[23:16], key_name(last_decoded[23:16]));
        $display("---------------------------------------------------------------");
    endtask

endmodule
