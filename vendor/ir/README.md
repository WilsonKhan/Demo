IR remote on the DE1-SoC (V2026.2)
==================================

The DE1-SoC has an IR receiver module on its edge (pin IRDA_RXD). The Terasic remote sends NEC
frames, and Terasic's IR_RECEIVE decodes them. This folder has that decoder on the DE1-SoC, a
shorter NEC decoder that does the same job (nec_decoder.sv), and a simulation model of the remote
and the receiver, so you can test a decoder without a remote.


Simulate
--------

    ./simulate.sh          the whole scenario, 0.8 s of simulated time; writes waveform.fst (0.5 MB)
    ./simulate.sh short    two presses and a 150 ms hold, 0.4 s simulated; the same waveform

The scenario presses Power, A and 5, holds CH+ for 400 ms (one frame, then three repeat codes), and
sends a frame whose inverted key byte is wrong. Both decoders must agree, and the run ends with
PASS or FAIL. The simulation takes about 10 s in our tests, after the Verilator build; then
GTKWave opens with ir.gtkw (the pin, the model, and both decoders).

The waveform leaves out the decoders' counters (tb/ir_trace.vlt): while they count they change on
every clock, and the run is 40 million clocks long, so they would make the file tens of megabytes.

Two things to know about Terasic's decoder:

- It reports a held key once. A repeat code is a 9 ms burst, a 2.25 ms space and a stop burst,
  with no data bits, so the decoder outputs nothing for it. nec_decoder reports repeat codes
  separately.
- oDATA_READY is a level about 1.8 ms long, not a pulse, and oDATA is loaded one clock after it
  rises. nec_decoder pulses valid for one clock.


Build (Quartus 18.1)
--------------------

Open quartus/ir.qpf and compile it (Processing > Start Compilation). To program it, open
Tools > Programmer: Hardware Setup (DE-SoC), Auto Detect (pick 5CSEMA5), select the 5CSEMA5 row,
Change File to output_files/ir.sof, tick Program/Configure and press Start.

The same from a Command Prompt in the quartus folder, with Quartus installed in its usual
place (change C:\intelFPGA_lite\18.1 if yours is elsewhere; @2: the FPGA is the second device
on the DE1-SoC's JTAG chain):

    C:\intelFPGA_lite\18.1\quartus\bin64\quartus_sh.exe --flow compile ir
    C:\intelFPGA_lite\18.1\quartus\bin64\quartus_pgm.exe -m jtag -o "p;output_files/ir.sof@2"

On Linux, run quartus_sh and quartus_pgm the same way, with Quartus's bin folder on the PATH.

In our tests (Quartus 18.1, 17 October 2026) it compiles in about a minute to 134 ALMs and 215
registers, with 0 critical warnings, and meets timing with 15.6 ns of setup slack on CLOCK_50
(Fmax 226.5 MHz).


On the board
------------

Point the remote at the receiver on the board's edge and press a key.

    HEX5..HEX2   the custom code
    HEX1..HEX0   the key code
    LEDR7..LEDR0 the inverted key code
    LEDR8        flickers while the receiver hears bursts (any 38 kHz remote, any protocol)
    LEDR9        a 200 ms flash on every accepted frame
    KEY0         reset

The key codes below are from Terasic's table for the remote (DE1-SoC User Manual, Table 5-5). The
manual gives no custom code: the model's 0x6B86 is not from it. None of these has been checked
against a real remote yet. The model sends whatever code you give it and the decoder shows what it
received, so a wrong entry here is a documentation fix, not a design bug.

    Power    0x12        0 .. 9      0x00 .. 0x09     CH+ / CH-     0x1A / 0x1E
    A        0x0F        B           0x13             C             0x10
    MUTE     0x0C        VOL+        0x1B             VOL-          0x1F
    MENU     0x11        RETURN      0x17             PLAY          0x16
    ADJUST < 0x14        ADJUST >    0x18


Files
-----

    rtl/       IR_RECEIVE_Terasic.v (Terasic's NEC decoder, 50 MHz), nec_decoder.sv (the same job in
               one always_ff), top_level.sv (IRDA_RXD to the HEX displays and LEDs), hex_digit.sv
    tb/        ir_tb.sv (the bench), ir_remote_model.sv (the remote and the receiver),
               ir_trace.vlt (keeps the counters out of the waveform), ir_trace_noclk.vlt (the same,
               and the clock too, for a text VCD; simulate.sh does not use it)
    quartus/   ir.qpf, ir.qsf (the DE1-SoC's own pin names), ir.sdc
    simulate.sh and ir.gtkw   the Verilator run and the GTKWave signal list
