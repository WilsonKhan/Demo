`timescale 1ns/1ps
/* verilator lint_off BLKSEQ */
/* verilator lint_off PROCASSINIT */
/* verilator lint_off SYNCASYNCNET */
// (Testbench style, harmless here: counters updated with '=' in always blocks, variables given a start value,
//  and rst_n resetting Terasic's decoder asynchronously and nec_decoder synchronously.)
/*
 *  ir_tb.sv -- the IR remote model driving Terasic's decoder (and the minimal nec_decoder next to it).
 *
 *  Scenario (about 0.8 s of simulated time):
 *    1. press Power (0x12), A (0x0F) and 5 (0x05): three frames, one data-ready each
 *    2. hold CH+ (0x1A) for 400 ms: one frame then three repeat codes; the Terasic decoder must report
 *       the key ONCE (repeat codes carry no data and never complete 32 bits)
 *    3. a raw frame whose inverted key byte is wrong: both decoders must reject it
 *  Plusargs: +short (two presses and a 150 ms hold, about 0.4 s: for a small waveform), +wave (trace even when short).
 */
module ir_tb;
    logic clk = 1'b0;  always #10 clk = ~clk;      // 50 MHz
    logic rst_n = 1'b0;
    wire  irda;

    int frames_sent, repeats_sent, frames_decoded, repeats_decoded, monitor_errors; logic [31:0] last_decoded;
    ir_remote_model remote (.irda_rxd(irda), .frames_sent, .repeats_sent, .frames_decoded, .repeats_decoded, .last_decoded, .monitor_errors);

    wire        ready;  wire [31:0] data;           // Terasic
    IR_RECEIVE  dut (.iCLK(clk), .iRST_n(rst_n), .iIRDA(irda), .oDATA_READY(ready), .oDATA(data));

    logic       nec_valid, nec_repeat; logic [31:0] nec_code;   // the minimal decoder
    nec_decoder u_nec (.clk, .rst(~rst_n), .ir(irda), .valid(nec_valid), .code(nec_code), .repeat_code(nec_repeat));

    // ---- what the decoders delivered ----
    logic ready_q = 1'b0;
    int   readies = 0, nec_valids = 0, nec_repeats = 0, fails = 0;
    logic [31:0] terasic_got [$];
    logic [31:0] nec_got [$];
    always @(posedge clk) begin
        ready_q <= ready;
        if (ready && !ready_q) begin
            readies++;
            @(posedge clk);                            // oDATA is loaded one clock after oDATA_READY rises
            terasic_got.push_back(data);
            $display("[tb @%0t] Terasic decoder: oDATA_READY, oDATA = 0x%08X (custom 0x%04X, key 0x%02X)", $time, data, data[15:0], data[23:16]);
        end
        if (nec_valid)  begin nec_valids++; nec_got.push_back(nec_code); $display("[tb @%0t] nec_decoder: valid, code = 0x%08X", $time, nec_code); end
        if (nec_repeat) begin nec_repeats++; $display("[tb @%0t] nec_decoder: repeat code", $time); end
    end

    task automatic expect_frames(input int n, input string what);
        if (readies != n)    begin fails++; $display("FAIL: %s: Terasic decoder reported %0d frame(s), expected %0d", what, readies, n); end
        if (nec_valids != n) begin fails++; $display("FAIL: %s: nec_decoder reported %0d frame(s), expected %0d", what, nec_valids, n); end
    endtask

    function automatic logic [31:0] word_of(input logic [7:0] key);
        return {~key, key, remote.CUSTOM_CODE};
    endfunction

    logic short_run = 1'b0;
    initial begin
        $timeformat(-3, 3, " ms", 0);       // the log's times in milliseconds
        short_run = $test$plusargs("short");
`ifdef VERILATOR
        if (!short_run || $test$plusargs("wave")) begin $dumpfile("waveform.fst"); $dumpvars(); end
`else
        $dumpfile("waveform.vcd"); $dumpvars();
`endif
        repeat (5) @(posedge clk); rst_n = 1'b1;
        #2ms;

        // 1. three presses (20 ms of idle line between them instead of the real 108 ms: it keeps the run short,
        //    and is more than the 9.5 ms a decoder needs to be ready for the next frame)
        remote.press(8'h12, 20);
        remote.press(8'h0F, 20);
        if (!short_run) remote.press(8'h05, 20);
        expect_frames(short_run ? 2 : 3, "after the presses");
        if (terasic_got.size() >= 2 && (terasic_got[0] != word_of(8'h12) || terasic_got[1] != word_of(8'h0F)))
            begin fails++; $display("FAIL: Terasic decoder words 0x%08X 0x%08X, expected 0x%08X 0x%08X", terasic_got[0], terasic_got[1], word_of(8'h12), word_of(8'h0F)); end
        if (nec_got.size() >= 2 && (nec_got[0] != word_of(8'h12) || nec_got[1] != word_of(8'h0F)))
            begin fails++; $display("FAIL: nec_decoder words 0x%08X 0x%08X, expected 0x%08X 0x%08X", nec_got[0], nec_got[1], word_of(8'h12), word_of(8'h0F)); end

        // 2. a held key: one frame, then repeat codes
        if (short_run) remote.hold(8'h1A, 150); else remote.hold(8'h1A, 400);
        expect_frames(short_run ? 3 : 4, "after the held key (repeat codes carry no data)");
        if (repeats_sent != (short_run ? 1 : 3)) begin fails++; $display("FAIL: remote sent %0d repeat codes, expected %0d", repeats_sent, short_run ? 1 : 3); end
        if (nec_repeats != repeats_sent) begin fails++; $display("FAIL: nec_decoder saw %0d repeat codes, the remote sent %0d", nec_repeats, repeats_sent); end
        if (repeats_decoded != repeats_sent) begin fails++; $display("FAIL: the model's monitor saw %0d repeat codes, the remote sent %0d", repeats_decoded, repeats_sent); end

        // 3. a corrupt frame: inverted key byte wrong
        if (!short_run) begin
            remote.send_raw_frame({8'h00, 8'h12, remote.CUSTOM_CODE}, 20);
            expect_frames(4, "after the corrupt frame (it must be rejected)");
            if (monitor_errors != 1) begin fails++; $display("FAIL: the model's monitor counted %0d problems, expected exactly 1 (the bad inverted byte)", monitor_errors); end
        end
        #10ms;
        remote.print_summary();
        if (frames_decoded != frames_sent - (short_run ? 0 : 1)) begin fails++; $display("FAIL: monitor decoded %0d good frames of %0d sent", frames_decoded, frames_sent); end
        if (last_decoded != word_of(8'h1A)) begin fails++; $display("FAIL: the model's last good frame is 0x%08X, expected 0x%08X (CH+)", last_decoded, word_of(8'h1A)); end
        if (fails != 0)     $display("FAILED: %0d problem(s)", fails);
        else if (short_run) $display("PASS: %0d frames decoded by both decoders, %0d repeat code ignored by the Terasic decoder and flagged by nec_decoder",
                                     readies, repeats_sent);
        else                $display("PASS: %0d frames decoded by both decoders, %0d repeat codes ignored by the Terasic decoder and flagged by nec_decoder, the corrupt frame rejected by both",
                                     readies, repeats_sent);
        $finish;
    end
endmodule
